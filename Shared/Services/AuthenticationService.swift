// Copyright © 2020 Metabolist. All rights reserved.

import Foundation
import Combine

struct AuthenticationService {
    private let environment: AppEnvironment
    private let networkClient: MastodonClient
    private let webAuthSessionContextProvider = WebAuthSessionContextProvider()

    init(environment: AppEnvironment) {
        self.environment = environment
        self.networkClient = MastodonClient(configuration: environment.URLSessionConfiguration)
    }
}

extension AuthenticationService {
    func authenticate(instanceURL: URL) -> AnyPublisher<UUID, Error> {
        let identityID = UUID()
        let redirectURL: URL

        do {
            redirectURL = try identityID.uuidString.url(scheme: MastodonAPI.OAuth.callbackURLScheme)
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }

        return authorizeApp(
            identityID: identityID,
            instanceURL: instanceURL,
            redirectURL: redirectURL,
            keychainService: environment.keychainService)
            .authenticationURL(instanceURL: instanceURL, redirectURL: redirectURL)
            .authenticate(
                webAuthSessionType: environment.webAuthSessionType,
                contextProvider: webAuthSessionContextProvider,
                callbackURLScheme: MastodonAPI.OAuth.callbackURLScheme)
            .extractCode()
            .requestAccessToken(
                networkClient: networkClient,
                identityID: identityID,
                instanceURL: instanceURL,
                redirectURL: redirectURL)
            .createIdentity(id: identityID, instanceURL: instanceURL, environment: environment)
    }
}

private extension AuthenticationService {
    func authorizeApp(
        identityID: UUID,
        instanceURL: URL,
        redirectURL: URL,
        keychainService: KeychainServiceType) -> AnyPublisher<AppAuthorization, Error> {
        let endpoint = AppAuthorizationEndpoint.apps(
            clientName: MastodonAPI.OAuth.clientName,
            redirectURI: redirectURL.absoluteString,
            scopes: MastodonAPI.OAuth.scopes,
            website: nil)
        let target = MastodonTarget(baseURL: instanceURL, endpoint: endpoint, accessToken: nil)

        return networkClient.request(target)
            .tryMap {
                let secretsService = SecretsService(identityID: identityID, keychainService: keychainService)
                try secretsService.set($0.clientId, forItem: .clientID)
                try secretsService.set($0.clientSecret, forItem: .clientSecret)

                return $0
            }
            .eraseToAnyPublisher()
    }
}

private extension Publisher where Output == AppAuthorization {
    func authenticationURL(instanceURL: URL, redirectURL: URL) -> AnyPublisher<(AppAuthorization, URL), Error> {
        tryMap { appAuthorization in
            guard var authorizationURLComponents = URLComponents(url: instanceURL, resolvingAgainstBaseURL: true) else {
                throw URLError(.badURL)
            }

            authorizationURLComponents.path = "/oauth/authorize"
            authorizationURLComponents.queryItems = [
                "client_id": appAuthorization.clientId,
                "scope": MastodonAPI.OAuth.scopes,
                "response_type": "code",
                "redirect_uri": redirectURL.absoluteString
            ].map { URLQueryItem(name: $0, value: $1) }

            guard let authorizationURL = authorizationURLComponents.url else {
                throw URLError(.badURL)
            }

            return (appAuthorization, authorizationURL)
        }
        .mapError { $0 as Error }
        .eraseToAnyPublisher()
    }
}

private extension Publisher where Output == (AppAuthorization, URL), Failure == Error {
    func authenticate(
        webAuthSessionType: WebAuthSessionType.Type,
        contextProvider: WebAuthSessionContextProvider,
        callbackURLScheme: String) -> AnyPublisher<(AppAuthorization, URL), Error> {
        flatMap { appAuthorization, url in
            webAuthSessionType.publisher(
                url: url,
                callbackURLScheme: callbackURLScheme,
                presentationContextProvider: contextProvider)
                .tryCatch { error -> AnyPublisher<URL?, Error> in
                    if (error as? WebAuthSessionError)?.code == .canceledLogin {
                        return Just(nil).setFailureType(to: Error.self).eraseToAnyPublisher()
                    }

                    throw error
                }
                .compactMap { $0 }
                .map { (appAuthorization, $0) }
        }
        .eraseToAnyPublisher()
    }
}

private extension Publisher where Output == (AppAuthorization, URL) {
    func extractCode() -> AnyPublisher<(AppAuthorization, String), Error> {
        tryMap { appAuthorization, url -> (AppAuthorization, String) in
            guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems,
                  let code = queryItems.first(where: { $0.name == MastodonAPI.OAuth.codeCallbackQueryItemName })?.value
            else { throw MastodonAPI.OAuthError.codeNotFound }

            return (appAuthorization, code)
        }
        .eraseToAnyPublisher()
    }
}

private extension Publisher where Output == (AppAuthorization, String), Failure == Error {
    func requestAccessToken(
        networkClient: HTTPClient,
        identityID: UUID,
        instanceURL: URL,
        redirectURL: URL) -> AnyPublisher<AccessToken, Error> {
        flatMap { appAuthorization, code -> AnyPublisher<AccessToken, Error> in
            let endpoint = AccessTokenEndpoint.oauthToken(
                clientID: appAuthorization.clientId,
                clientSecret: appAuthorization.clientSecret,
                code: code,
                grantType: MastodonAPI.OAuth.grantType,
                scopes: MastodonAPI.OAuth.scopes,
                redirectURI: redirectURL.absoluteString)
            let target = MastodonTarget(baseURL: instanceURL, endpoint: endpoint, accessToken: nil)

            return networkClient.request(target)
        }
        .eraseToAnyPublisher()
    }
}

private extension Publisher where Output == AccessToken {
    func createIdentity(id: UUID, instanceURL: URL, environment: AppEnvironment) -> AnyPublisher<UUID, Error> {
        tryMap { accessToken -> (UUID, URL) in
            let secretsService = SecretsService(identityID: id, keychainService: environment.keychainService)

            try secretsService.set(accessToken.accessToken, forItem: .accessToken)

            return (id, instanceURL)
        }
        .flatMap(environment.identityDatabase.createIdentity)
        .map { id }
        .eraseToAnyPublisher()
    }
}

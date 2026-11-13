//
//  GoogleClient.swift
//  boringNotch
//
//  The OAuth client Notchway signs in with. A desktop app cannot keep this pair secret: Google
//  treats the "secret" of a desktop client as public, and the sign-in is protected by PKCE and
//  by the user's own consent (see GoogleAuth). It only identifies the app, it opens no account.
//
//  Anyone who wants full control can enter their own client in the settings; that one wins.
//

import Defaults
import Foundation

enum GoogleClient {
    /// Notchway's own client (Google Cloud project "Notchway", type "Desktop app"). The values are
    /// not in the repository: `island-build.sh` fills GoogleClientBuiltIn.swift while building a release.
    static let builtInID = GoogleClientBuiltIn.id
    static let builtInSecret = GoogleClientBuiltIn.secret

    /// A client typed in by the user replaces the built-in one.
    static var usesOwn: Bool {
        !Defaults[.islandGoogleClientID].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var id: String {
        usesOwn ? Defaults[.islandGoogleClientID].trimmingCharacters(in: .whitespacesAndNewlines) : builtInID
    }

    static var secret: String? {
        let value = usesOwn ? IslandKeychain.read("clientSecret") : builtInSecret
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static var isConfigured: Bool { !id.isEmpty && secret != nil }
}

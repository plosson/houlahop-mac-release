#!/usr/bin/env bash
# Shared release steps for houlahop Mac apps: archive, Developer ID export, notarization, zip and pkg,
# Sparkle appcast, GitHub release and Homebrew cask.
#
# An app's scripts/release.sh sets its configuration, sources this file, then calls the steps it needs:
#
#   NAME="Copycat"                        # app bundle name, without .app
#   FILE_NAME="Copycat-$VERSION"          # base name of the zip and pkg
#   REPO="plosson/copycat"                # GitHub repository that holds the releases
#   BUNDLE_ID="com.plosson.copycat"
#   PROJECT="$ROOT/Copycat.xcodeproj"
#   SCHEME="Copycat"
#   BUILD="$ROOT/build/release"
#   TEAM="XXXXXXXXXX"                     # Apple team ID
#   SPARKLE_ACCOUNT="copycat"             # keychain account of the Sparkle signing key (generate_keys --account)
#   CASK="copycat"                        # cask token in plosson/homebrew-tap
#   CASK_DESC="Copies files from web pages to the clipboard"
#   MIN_MACOS="sonoma"                    # cask depends_on macos
#
# Needs: "Developer ID Application" and "Developer ID Installer" certificates in the keychain, asc (App Store
#   Connect CLI) signed in with an API key (`asc auth status`), the Sparkle signing key in the keychain, and gh.

SPARKLE_VERSION="2.10.0"
TAP_REPO="plosson/homebrew-tap"
TAP_NAME="plosson/tap"
RELEASE_CACHE="$HOME/Library/Caches/houlahop-mac-release"

# Stops with a message.
release_fail() {
  echo "✗ $*" >&2
  exit 1
}

# Checks the version argument (X.Y.Z) and sets VERSION and TAG.
release_version() {
  VERSION="${1:-}"
  [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || release_fail "usage: scripts/release.sh X.Y.Z"
  TAG="v$VERSION"
}

# Stops unless the working tree is clean and the GitHub release does not exist yet.
release_check_clean() {
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || release_fail "working tree has uncommitted changes"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    release_fail "release $TAG already exists"
  fi
}

# Empties BUILD.
release_clean_build() {
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
}

# Archives the Release configuration. MARKETING_VERSION and CURRENT_PROJECT_VERSION are both the release version,
# so Sparkle compares versions it can order. Extra arguments go to xcodebuild.
release_archive() {
  xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$BUILD/$SCHEME.xcarchive" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" DEVELOPMENT_TEAM="$TEAM" "$@"
}

# Exports the archive with Developer ID signing and sets APP. An optional argument names the provisioning profile
# to sign BUNDLE_ID with.
release_export() {
  local profile="${1:-}" profiles=""
  if [[ -n "$profile" ]]; then
    profiles="<key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$BUNDLE_ID</key><string>$profile</string>
  </dict>"
  fi
  cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  $profiles
</dict>
</plist>
PLIST
  xcodebuild -exportArchive \
    -archivePath "$BUILD/$SCHEME.xcarchive" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -exportPath "$BUILD/export"
  APP="$BUILD/export/$NAME.app"
  [[ -d "$APP" ]] || release_fail "export did not produce $NAME.app"
}

# Downloads the active provisioning profile with this name from App Store Connect, so the export can use it.
release_install_profile() {
  local name="$1" dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" json
  mkdir -p "$dir"
  json="$(asc profiles list | jq --arg name "$name" '[.data[] | select(.attributes.name == $name and .attributes.profileState == "ACTIVE")][0]')"
  [[ "$json" != "null" ]] || release_fail "no active provisioning profile named \"$name\""
  jq -r '.attributes.profileContent' <<<"$json" | base64 -d > "$dir/$(jq -r '.attributes.uuid' <<<"$json").provisionprofile"
}

# Notarizes a zip, dmg or pkg, and stops with Apple's list of issues unless it is Accepted.
# asc exits non-zero when Apple refuses the file, so its output is read before its exit code.
release_notarize() {
  local out id status
  out="$(asc notarization submit --file "$1" --wait)" || true
  id="$(jq -r '.data.id // .id // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$id" ]] || { echo "$out" >&2; release_fail "notarization was not accepted"; }
  status="$(asc notarization status --id "$id" | jq -r '.data.attributes.status')"
  echo "Notarization of $(basename "$1") ($id): $status"
  if [[ "$status" != "Accepted" ]]; then
    curl -fsS "$(asc notarization log --id "$id" | jq -r '.data.attributes.developerLogUrl')" | jq '.issues' >&2 || true
    release_fail "notarization was not accepted"
  fi
}

# Notarizes and staples APP, then zips it as ZIP (the file Sparkle and Homebrew download).
release_notarize_app() {
  ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
  release_notarize "$BUILD/notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
  ZIP="$BUILD/$FILE_NAME.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
}

# Builds, signs, notarizes and staples PKG: an installer that always puts the app in /Applications. It is not
# relocatable, so it never overwrites another copy of the app found elsewhere on the disk.
release_pkg() {
  local installer_id
  PKG="$BUILD/$FILE_NAME.pkg"
  installer_id="$(security find-identity -v | awk -v team="($TEAM)\"" '/Developer ID Installer/ && index($0, team) { print $2; exit }')"
  [[ -n "$installer_id" ]] || release_fail "no Developer ID Installer certificate for team $TEAM"
  rm -rf "$BUILD/pkgroot"
  mkdir -p "$BUILD/pkgroot"
  ditto "$APP" "$BUILD/pkgroot/$NAME.app"
  pkgbuild --analyze --root "$BUILD/pkgroot" "$BUILD/component.plist"
  plutil -replace 0.BundleIsRelocatable -bool NO "$BUILD/component.plist"
  pkgbuild --root "$BUILD/pkgroot" --component-plist "$BUILD/component.plist" \
    --identifier "$BUNDLE_ID.pkg" --version "$VERSION" --install-location /Applications \
    --sign "$installer_id" "$PKG"
  release_notarize "$PKG"
  xcrun stapler staple "$PKG"
  spctl --assess --type install --verbose "$PKG"
}

# Writes APPCAST, the Sparkle feed for ZIP, signed with the SPARKLE_ACCOUNT key. The app reads
# releases/latest/download/appcast.xml, so each release carries a feed with one item: its own zip.
release_appcast() {
  local sparkle="$RELEASE_CACHE/Sparkle-$SPARKLE_VERSION"
  if [[ ! -x "$sparkle/bin/generate_appcast" ]]; then
    mkdir -p "$sparkle"
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
      | tar -xJ -C "$sparkle"
  fi
  rm -rf "$BUILD/appcast"
  mkdir -p "$BUILD/appcast"
  cp "$ZIP" "$BUILD/appcast/"
  APPCAST="$BUILD/appcast.xml"
  "$sparkle/bin/generate_appcast" --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    -o "$APPCAST" "$BUILD/appcast"
  grep -q "sparkle:edSignature" "$APPCAST" || release_fail "appcast has no EdDSA signature"
}

# Publishes the GitHub release with the pkg, the zip and the appcast. Extra arguments go to gh release create.
release_publish() {
  gh release create "$TAG" "$PKG" "$ZIP" "$APPCAST" --repo "$REPO" --title "$NAME $VERSION" "$@" \
    --notes "Open $FILE_NAME.pkg to install $NAME in Applications. Or download $FILE_NAME.zip, unzip, move \"$NAME.app\" to Applications and open it. Or install with Homebrew: brew install --cask $TAP_NAME/$CASK"
  echo "✓ published $TAG"
}

# Writes Casks/CASK.rb in the Homebrew tap for the zip of this release, then commits and pushes it.
release_cask() {
  local tap="$RELEASE_CACHE/homebrew-tap" sha
  if [[ -d "$tap/.git" ]]; then
    git -C "$tap" pull --quiet --ff-only
  else
    gh repo clone "$TAP_REPO" "$tap" -- --quiet
  fi
  sha="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  mkdir -p "$tap/Casks"
  # The url uses #{version} so the file name stays in sync; FILE_NAME is "<prefix>-$VERSION".
  cat > "$tap/Casks/$CASK.rb" <<RUBY
cask "$CASK" do
  version "$VERSION"
  sha256 "$sha"

  url "https://github.com/$REPO/releases/download/v#{version}/${FILE_NAME%"$VERSION"}#{version}.zip"
  name "$NAME"
  desc "$CASK_DESC"
  homepage "https://github.com/$REPO"

  # Sparkle updates the app in place; brew upgrade leaves it alone unless --greedy.
  auto_updates true
  depends_on macos: ">= :$MIN_MACOS"

  app "$NAME.app"

  zap trash: [
    "~/Library/Caches/$BUNDLE_ID",
    "~/Library/HTTPStorages/$BUNDLE_ID",
    "~/Library/Preferences/$BUNDLE_ID.plist",
  ]
end
RUBY
  git -C "$tap" add "Casks/$CASK.rb"
  git -C "$tap" commit --quiet -m "$CASK $VERSION"
  git -C "$tap" push --quiet
  echo "✓ updated cask $CASK to $VERSION"
}

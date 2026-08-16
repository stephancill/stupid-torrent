#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../Package.swift" || -f "$SCRIPT_DIR/../xtool.yml" ]]; then
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    PROJECT_DIR="$(pwd)"
fi
GLOBAL_ENV="${GLOBAL_ENV:-$HOME/.config/opencode/env/appstore-release.env}"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env.local}"
RELEASE_DIR="$PROJECT_DIR/.release"
KEYCHAIN="$RELEASE_DIR/build.keychain"
KEYCHAIN_PASS="$RELEASE_DIR/build.keychain.pass"
PROJECT_SLUG="${PROJECT_SLUG:-${XCODE_SCHEME:-app}}"
PROJECT_NAME="${PROJECT_NAME:-$PROJECT_SLUG}"
PROFILE="$RELEASE_DIR/$PROJECT_SLUG.mobileprovision"
EXTENSION_BUNDLE_IDS="${EXTENSION_BUNDLE_IDS:-}"  # space-separated, optional

load_env() {
    local f="$1"
    if [[ -f "$f" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$f"
        set +a
    fi
}

load_env "$GLOBAL_ENV"
load_env "$ENV_FILE"

usage() {
    cat <<'EOF'
Usage: release.sh [step...]

Steps run in order if none given:
  register-bundle   ensure the App ID is registered on the developer portal
  cert              mint (if needed) + install an Apple Distribution cert + private key
  profile           create (if needed) + install the App Store provisioning profile
  archive           xcodebuild archive the app (manual signing, pinned profile)
  export            export the archive to an .ipa
  upload            upload the .ipa to App Store Connect / TestFlight
  whats-new         set the latest build's 'What to Test' note (TestFlight)
  groups            create (if needed) internal + external beta groups, add latest build
  submit            submit the latest build for external beta review (App Review)
  all               register-bundle + cert + profile + archive + export + upload + whats-new + groups + submit

Config is loaded from (later sources override earlier ones):
  1. $GLOBAL_ENV  (global credentials, outside any git repo)
  2. <project>/.env.local  (project-specific, gitignored)
  3. command-line arguments (highest priority)

Environment / env file variables:
  ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_PATH   (global credentials)
  DEVELOPER_TEAM_ID, DIST_NAME                          (global team + cert CN)
  APP_BUNDLE_ID, XCODE_WORKSPACE, XCODE_SCHEME           (project-specific)
  XCODE_APP_SCHEME                                      (optional: real .app scheme, e.g. <Product>-App;
                                                          auto-detected as <XCODE_SCHEME>-App if present)
  EXTENSION_BUNDLE_IDS                                  (optional, space-separated: additional bundle IDs
                                                          needing their own App Store profile + export mapping)
  PROJECT_SLUG, PROJECT_NAME                             (optional, default from XCODE_SCHEME)
  BETA_REVIEW_FIRST_NAME, BETA_REVIEW_LAST_NAME,         (submit step, from env)
  BETA_REVIEW_PHONE, BETA_REVIEW_EMAIL
  BETA_APP_DESCRIPTION, BETA_APP_FEEDBACK_EMAIL, BETA_APP_MARKETING_URL, BETA_APP_PRIVACY_POLICY_URL
  BETA_WHAT_TO_TEST                                  (optional: 'What to Test' note for the latest build,
                                                          set per release in .env.local or via --whats-new)
EOF
}

# --- argument parsing ------------------------------------------------------

WANTED_STEPS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key-id) ASC_API_KEY_ID="$2"; shift 2 ;;
        --api-issuer) ASC_API_ISSUER_ID="$2"; shift 2 ;;
        --api-key-path) ASC_API_KEY_PATH="$2"; shift 2 ;;
        --team-id) DEVELOPER_TEAM_ID="$2"; shift 2 ;;
        --bundle-id) APP_BUNDLE_ID="$2"; shift 2 ;;
        --workspace) XCODE_WORKSPACE="$2"; shift 2 ;;
        --scheme) XCODE_SCHEME="$2"; shift 2 ;;
        --whats-new) WHATS_NEW="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) WANTED_STEPS+=("$1"); shift ;;
    esac
done

if [[ ${#WANTED_STEPS[@]} -eq 0 ]]; then
    WANTED_STEPS=(all)
fi

require() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "ERROR: $name is not set. Set it in $GLOBAL_ENV, project .env.local, or pass the matching --flag." >&2
        exit 1
    fi
}

for v in ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_PATH DEVELOPER_TEAM_ID DIST_NAME APP_BUNDLE_ID XCODE_WORKSPACE XCODE_SCHEME; do
    require "$v"
done

# --- helpers ---------------------------------------------------------------

ASC_API="https://api.appstoreconnect.apple.com/v1"
STAMP="$(date +%Y%m%d-%H%M)"
DIST_IDENTITY="Apple Distribution: $DIST_NAME ($DEVELOPER_TEAM_ID)"
mkdir -p "$RELEASE_DIR"

jwt() {
    local now exp
    now=$(date +%s)
    exp=$((now + 1200))
    python3 - "$ASC_API_KEY_ID" "$ASC_API_ISSUER_ID" "$ASC_API_KEY_PATH" "$now" "$exp" <<'PYEOF'
import base64, json, sys

def b64url(data):
    if isinstance(data, str):
        data = data.encode()
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

key_id, issuer, key_path, iat, exp = sys.argv[1:6]
header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
payload = {"iss": issuer, "iat": int(iat), "exp": int(exp), "aud": "appstoreconnect-v1"}
header_b64 = b64url(json.dumps(header, separators=(",", ":")))
payload_b64 = b64url(json.dumps(payload, separators=(",", ":")))
signing_input = f"{header_b64}.{payload_b64}"

from cryptography.hazmat.primitives.serialization import load_pem_private_key
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives import hashes
with open(key_path, "rb") as f:
    key = load_pem_private_key(f.read(), password=None)
der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
r, s = utils.decode_dss_signature(der)
sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
print(f"{signing_input}.{b64url(sig)}")
PYEOF
}

TOKEN="$(jwt)"

api_get() {
    curl -s -H "Authorization: Bearer $TOKEN" "$ASC_API/$1"
}

api_post() {
    local path="$1" body="$2"
    curl -s -X POST -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$body" "$ASC_API/$path"
}

api_patch() {
    local path="$1" body="$2"
    curl -s -X PATCH -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$body" "$ASC_API/$path"
}

log() { echo -e "\n==> $*"; }

# The workspace scheme (e.g. StupidAuthenticator) only builds an executable. The
# real .app lives under the <Product>-App scheme. Use XCODE_APP_SCHEME if the
# user set it, else auto-detect <XCODE_SCHEME>-App, else fall back to XCODE_SCHEME.
app_scheme() {
    if [[ -n "${XCODE_APP_SCHEME:-}" ]]; then
        echo "$XCODE_APP_SCHEME"
        return
    fi
    local candidate="${XCODE_SCHEME}-App"
    if xcodebuild -list -workspace "$PROJECT_DIR/$XCODE_WORKSPACE" 2>/dev/null | grep -q "        $candidate"; then
        echo "$candidate"
    else
        echo "$XCODE_SCHEME"
    fi
}

# xtool generates the .xcodeproj under xtool/.xtool-tmp/<Product>.xcodeproj.
xcodeproj_for_workspace() {
    local ws_dir ws_base
    ws_dir="$(dirname "$PROJECT_DIR/$XCODE_WORKSPACE")"
    ws_base="$(basename "$XCODE_WORKSPACE" .xcworkspace)"
    echo "$ws_dir/.xtool-tmp/$ws_base.xcodeproj"
}

# A distribution profile exists per bundle ID. EXTENSION_BUNDLE_IDS are separate
# bundle IDs (e.g. app extension appexes) that each need their own profile.
all_bundle_ids() {
    echo "$APP_BUNDLE_ID $EXTENSION_BUNDLE_IDS"
}

profile_name_for() {
    local bundle_id="$1"
    if [[ "$bundle_id" == "$APP_BUNDLE_ID" ]]; then
        echo "$PROJECT_NAME AppStore"
    else
        local suffix
        suffix="$(echo "$bundle_id" | awk -F. '{print $NF}' | sed 's/_/-/g')"
        echo "${PROJECT_NAME}${suffix:+ $suffix} AppStore"
    fi
}

profile_file_for() {
    local bundle_id="$1"
    if [[ "$bundle_id" == "$APP_BUNDLE_ID" ]]; then
        echo "$PROFILE"
    else
        echo "$RELEASE_DIR/$(echo "$bundle_id" | tr '.' '-').mobileprovision"
    fi
}

keychain_unlock() {
    if [[ -f "$KEYCHAIN" ]]; then
        security unlock-keychain -p "$(cat "$KEYCHAIN_PASS")" "$KEYCHAIN" >/dev/null 2>&1
        security list-keychains -d user -s login.keychain-db "$KEYCHAIN"
    fi
}

# --- steps -----------------------------------------------------------------

register_bundle() {
    log "Registering bundle IDs"
    local bundle_id existing
    for bundle_id in $(all_bundle_ids); do
        existing=$(api_get "bundleIds?filter%5Bidentifier%5D=${bundle_id}" | jq -r --arg id "$bundle_id" '.data[] | select(.attributes.identifier == $id) | .id // empty' | head -1)
        if [[ -n "$existing" ]]; then
            echo "Already registered: $bundle_id ($existing)"
            continue
        fi
        api_post "bundleIds" "$(jq -n --arg name "$PROJECT_NAME" --arg id "$bundle_id" '{data:{type:"bundleIds",attributes:{name:$name,identifier:$id,platform:"IOS"}}}')" \
            | jq -r '"Registered \(.data.attributes.identifier) (\(.data.id))" // .errors[0].detail'
    done
}

cert() {
    log "Ensuring Apple Distribution cert"
    if [[ -f "$KEYCHAIN" ]] && security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | rg -q "Apple Distribution"; then
        echo "Reusing existing identity in $KEYCHAIN"
        keychain_unlock
        security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null
        return
    fi

    local csr keydir keyfile
    keydir="$(mktemp -d)"
    keyfile="$keydir/dist.key"
    openssl genrsa -out "$keyfile" 2048 >/dev/null 2>&1
    openssl req -new -key "$keyfile" -subj "/CN=Apple Distribution: ${DIST_NAME} (${DEVELOPER_TEAM_ID})" \
        -out "$keydir/dist.csr" >/dev/null 2>&1
    local csr_content
    csr_content=$(cat "$keydir/dist.csr")

    local resp
    resp=$(api_post "certificates" "$(jq -n --arg csr "$csr_content" --arg team "$DEVELOPER_TEAM_ID" \
        '{data:{type:"certificates",attributes:{csrContent:$csr,certificateType:"DISTRIBUTION"}}}')")
    local cert_id cert_content
    cert_id=$(echo "$resp" | jq -r '.data.id // empty')
    cert_content=$(echo "$resp" | jq -r '.data.attributes.certificateContent // empty')
    if [[ -z "$cert_id" ]]; then
        echo "ERROR: cert creation failed: $(echo "$resp" | jq -r '.errors[0].detail // "unknown"')" >&2
        exit 1
    fi
    echo "Minted cert $cert_id"
    echo "$cert_id" > "$RELEASE_DIR/dist-cert-id"

    local certfile
    certfile="$keydir/dist.cer"
    echo "$cert_content" | base64 --decode > "$certfile"

    local kc_pass
    kc_pass="$(openssl rand -hex 16)"
    rm -f "$KEYCHAIN"
    security create-keychain -p "$kc_pass" "$KEYCHAIN" >/dev/null 2>&1
    security set-keychain-settings -lut 21600 "$KEYCHAIN" >/dev/null 2>&1
    security unlock-keychain -p "$kc_pass" "$KEYCHAIN" >/dev/null 2>&1
    security import "$certfile" -k "$KEYCHAIN" -A >/dev/null 2>&1
    security import "$keyfile" -k "$KEYCHAIN" -A >/dev/null 2>&1
    echo "$kc_pass" > "$KEYCHAIN_PASS"
    security list-keychains -d user -s login.keychain-db "$KEYCHAIN"

    echo "Cert + key installed in $KEYCHAIN (password saved to $KEYCHAIN_PASS)"
    echo "NOTE: .release/ is gitignored, so this never gets committed."
}

profile() {
    log "Ensuring App Store provisioning profile"
    local cert_id
    if [[ -f "$RELEASE_DIR/dist-cert-id" ]]; then
        cert_id="$(cat "$RELEASE_DIR/dist-cert-id")"
        echo "Using recorded cert $cert_id (from .release/dist-cert-id)"
    else
        cert_id=$(api_get "certificates?filter%5BcertificateType%5D=DISTRIBUTION" | jq -r '.data[0].id // empty')
    fi
    if [[ -z "$cert_id" ]]; then
        echo "ERROR: no DISTRIBUTION cert. Run: release.sh cert" >&2
        exit 1
    fi

    local bundle_id name existing
    for bundle_id in $(all_bundle_ids); do
        local bid
        bid=$(api_get "bundleIds?filter%5Bidentifier%5D=${bundle_id}" | jq -r --arg id "$bundle_id" '.data[] | select(.attributes.identifier == $id) | .id // empty' | head -1)
        if [[ -z "$bid" ]]; then
            echo "ERROR: bundle ID $bundle_id not registered. Run: release.sh register-bundle" >&2
            exit 1
        fi
        name="$(profile_name_for "$bundle_id")"
        existing=$(api_get "profiles?filter%5BprofileType%5D=IOS_APP_STORE&filter%5Bname%5D=${name// /%20}" | jq -r '.data[0].id // empty')
        if [[ -n "$existing" ]]; then
            echo "Existing profile $existing ($name)"
        else
            local resp
            resp=$(api_post "profiles" "$(jq -n --arg name "$name" --arg bundle "$bid" --arg cert "$cert_id" \
                '{data:{type:"profiles",attributes:{name:$name,profileType:"IOS_APP_STORE"},relationships:{bundleId:{data:{type:"bundleIds",id:$bundle}},certificates:{data:[{type:"certificates",id:$cert}]}}}}')")
            existing=$(echo "$resp" | jq -r '.data.id // empty')
            if [[ -z "$existing" ]]; then
                echo "ERROR: profile creation failed for $bundle_id: $(echo "$resp" | jq -r '.errors[0].detail // "unknown"')" >&2
                exit 1
            fi
            echo "Created profile $existing ($name)"
        fi

        local pfile
        pfile="$(profile_file_for "$bundle_id")"
        api_get "profiles/$existing" | jq -r '.data.attributes.profileContent' | base64 --decode > "$pfile"
        echo "Profile saved to $pfile"
        cp "$pfile" "$HOME/Library/MobileDevice/Provisioning Profiles/$(basename "$pfile")"
        echo "Profile installed in ~/Library/MobileDevice/Provisioning Profiles"
    done
}

archive() {
    log "Archiving"
    keychain_unlock
    local scheme pbxproj patch_args
    scheme="$(app_scheme)"
    if [[ "$scheme" != "$XCODE_SCHEME" ]]; then
        echo "Using app scheme: $scheme (workspace scheme $XCODE_SCHEME only builds an executable)"
    fi

    # The single PROVISIONING_PROFILE_SPECIFIER passed to xcodebuild signs EVERY
    # target (including app extensions) with the app's profile, which App Store
    # rejects. Pin per-target signing in the generated xcodeproj instead so each
    # target gets its own profile. The pbxproj is regenerated by xtool, so this
    # patch is safe to re-apply on every archive.
    local EXTRA_SIGNING_ARGS=()
    if [[ -n "$EXTENSION_BUNDLE_IDS" ]]; then
        local pbxproj patch_args
        pbxproj="$(xcodeproj_for_workspace)/project.pbxproj"
        if [[ ! -f "$pbxproj" ]]; then
            echo "ERROR: expected generated xcodeproj at $pbxproj. Run: xtool dev generate-xcode-project" >&2
            exit 1
        fi
        patch_args=()
        for bundle_id in $(all_bundle_ids); do
            patch_args+=("$bundle_id:$(profile_name_for "$bundle_id")")
        done
        python3 "$SCRIPT_DIR/patch_target_signing.py" "$pbxproj" "$DIST_IDENTITY" "${patch_args[@]}"
        # Per-target signing is pinned in the pbxproj; do NOT pass a global
        # PROVISIONING_PROFILE_SPECIFIER or PRODUCT_BUNDLE_IDENTIFIER (each would
        # override the per-target values and sign/stamp every target with the
        # app's profile/bundle ID).
        EXTRA_SIGNING_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DIST_IDENTITY")
    else
        EXTRA_SIGNING_ARGS=(
            PRODUCT_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID"
            CODE_SIGN_STYLE=Manual
            CODE_SIGN_IDENTITY="$DIST_IDENTITY"
            PROVISIONING_PROFILE_SPECIFIER="$(profile_name_for "$APP_BUNDLE_ID")"
        )
    fi

    xcodebuild \
        -workspace "$PROJECT_DIR/$XCODE_WORKSPACE" \
        -scheme "$scheme" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$RELEASE_DIR/${PROJECT_SLUG}-$STAMP.xcarchive" \
        DEVELOPMENT_TEAM="$DEVELOPER_TEAM_ID" \
        "${EXTRA_SIGNING_ARGS[@]}" \
        archive
}

export_ipa() {
    log "Exporting IPA"
    local archive exportdir
    archive="$(ls -dt "$RELEASE_DIR"/${PROJECT_SLUG}-*.xcarchive 2>/dev/null | head -1)"
    keychain_unlock

    # provisioningProfiles must map EVERY bundle ID (app + extensions) to its
    # profile UUID, or export fails with "requires a provisioning profile with
    # the App Groups and AutoFill Credential Provider features".
    local prov_entries=""
    local bundle_id pfile prof_uuid
    for bundle_id in $(all_bundle_ids); do
        pfile="$(profile_file_for "$bundle_id")"
        prof_uuid=$(security cms -D -i "$pfile" 2>/dev/null | plutil -p - 2>/dev/null | sed -n 's/.*"UUID" => "\(.*\)"/\1/p' | head -1)
        if [[ -z "$prof_uuid" ]]; then
            echo "ERROR: could not read UUID from $pfile" >&2
            exit 1
        fi
        prov_entries+="        <key>$bundle_id</key>\n        <string>$prof_uuid</string>\n"
    done

    exportdir="$RELEASE_DIR/export-$STAMP"
    mkdir -p "$exportdir"
    local opts="$exportdir/ExportOptions.plist"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n    <key>method</key>\n    <string>app-store</string>\n    <key>destination</key>\n    <string>export</string>\n    <key>stripSwiftSymbols</key>\n    <true/>\n    <key>uploadBitcode</key>\n    <false/>\n    <key>uploadSymbols</key>\n    <true/>\n    <key>teamID</key>\n    <string>%s</string>\n    <key>signingStyle</key>\n    <string>manual</string>\n    <key>provisioningProfiles</key>\n    <dict>\n%b    </dict>\n</dict>\n</plist>\n' "$DEVELOPER_TEAM_ID" "$prov_entries" > "$opts"
    xcodebuild -exportArchive \
        -archivePath "$archive" \
        -exportPath "$exportdir" \
        -exportOptionsPlist "$opts"
    echo "IPA: $(find "$exportdir" -maxdepth 1 -name '*.ipa' | head -1)"
}

upload() {
    log "Uploading to App Store Connect"
    local ipa
    ipa="$(ls -dt "$RELEASE_DIR"/export-*/*.ipa 2>/dev/null | head -1)"
    if [[ -z "$ipa" ]]; then
        echo "ERROR: no IPA found. Run: release.sh export" >&2
        exit 1
    fi
    echo "Uploading $ipa"
    xcrun altool --upload-app -f "$ipa" -t ios \
        --apiIssuer "$ASC_API_ISSUER_ID" --apiKey "$ASC_API_KEY_ID"
}

ensure_group() {
    local name="$1" internal="$2" app_id group_id resp
    app_id=$(api_get "apps?filter%5BbundleId%5D=${APP_BUNDLE_ID}" | jq -r '.data[0].id // empty')
    if [[ -z "$app_id" ]]; then
        echo "ERROR: app record not found for $APP_BUNDLE_ID (create it in App Store Connect web UI first)" >&2
        exit 1
    fi
    group_id=$(api_get "betaGroups?filter%5Bapp%5D=${app_id}&filter%5Bname%5D=${name// /%20}" | jq -r '.data[0].id // empty')
    if [[ -n "$group_id" ]]; then
        echo "$group_id"
        return
    fi
    resp=$(api_post "betaGroups" "$(jq -n --arg name "$name" --arg internal "$internal" --arg app "$app_id" \
        '{data:{type:"betaGroups",attributes:{name:$name,isInternalGroup:$internal},relationships:{app:{data:{type:"apps",id:$app}}}}}')")
    group_id=$(echo "$resp" | jq -r '.data.id // empty')
    if [[ -z "$group_id" ]]; then
        echo "ERROR: group creation failed: $(echo "$resp" | jq -r '.errors[0].detail // "unknown"')" >&2
        exit 1
    fi
    echo "$group_id"
}

groups() {
    log "Adding latest build to external beta group"
    local app_id build_id
    app_id=$(api_get "apps?filter%5BbundleId%5D=${APP_BUNDLE_ID}" | jq -r '.data[0].id // empty')
    build_id=$(api_get "builds?filter%5Bapp%5D=${app_id}&sort=-uploadedDate" | jq -r '.data[0].id // empty')
    if [[ -z "$build_id" ]]; then
        echo "ERROR: no build found for $APP_BUNDLE_ID. Run: release.sh upload" >&2
        exit 1
    fi
    echo "Latest build: $build_id"

    # Internal testers see every build automatically; the API rejects assigning
    # builds to an internal group (422 "Builds cannot be assigned to this
    # internal group"). Only the external group needs the explicit relationship.
    local external_group
    external_group="$(ensure_group "External Testers" false)"
    echo "External group: $external_group"
    local body
    body="$(jq -n --arg b "$build_id" '{data:[{type:"builds",id:$b}]}')"
    curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d "$body" \
        "https://api.appstoreconnect.apple.com/v1/betaGroups/$external_group/relationships/builds" \
        -o /dev/null -w "Added build to external group: HTTP %{http_code}\n"
}

whats_new() {
    log "Setting the 'What to Test' note on the latest build"
    local note="${WHATS_NEW:-${BETA_WHAT_TO_TEST:-}}"
    if [[ -z "$note" ]]; then
        echo "Skipping: set BETA_WHAT_TO_TEST (or pass --whats-new) to update the note." >&2
        return
    fi
    local app_id build_id
    app_id=$(api_get "apps?filter%5BbundleId%5D=${APP_BUNDLE_ID}" | jq -r '.data[0].id // empty')
    if [[ -z "$app_id" ]]; then
        echo "ERROR: app record not found for $APP_BUNDLE_ID (create it in App Store Connect web UI first)" >&2
        exit 1
    fi
    build_id=$(api_get "builds?filter%5Bapp%5D=${app_id}&sort=-uploadedDate" | jq -r '.data[0].id // empty')
    if [[ -z "$build_id" ]]; then
        echo "ERROR: no build found for $APP_BUNDLE_ID. Run: release.sh upload" >&2
        exit 1
    fi
    echo "Latest build: $build_id"

    local loc_id
    loc_id=$(api_get "builds/$build_id/betaBuildLocalizations" | jq -r '.data[0].id // empty')
    if [[ -z "$loc_id" ]]; then
        echo "ERROR: no betaBuildLocalization for build $build_id (wait for processing)" >&2
        exit 1
    fi
    echo "Updating betaBuildLocalization $loc_id"
    api_patch "betaBuildLocalizations/$loc_id" "$(jq -n --arg id "$loc_id" --arg n "$note" \
        '{data:{type:"betaBuildLocalizations",id:$id,attributes:{whatsNew:$n}}}')" \
        | jq -r '"whatsNew (\(.data.attributes.locale // "?")): \(.data.attributes.whatsNew)"'
}

submit() {
    log "Submitting latest build for external beta review"
    require BETA_REVIEW_FIRST_NAME
    require BETA_REVIEW_LAST_NAME
    require BETA_REVIEW_PHONE
    require BETA_REVIEW_EMAIL
    require BETA_APP_DESCRIPTION
    require BETA_APP_FEEDBACK_EMAIL
    require BETA_APP_MARKETING_URL
    require BETA_APP_PRIVACY_POLICY_URL
    local app_id build_id
    app_id=$(api_get "apps?filter%5BbundleId%5D=${APP_BUNDLE_ID}" | jq -r '.data[0].id // empty')
    if [[ -z "$app_id" ]]; then
        echo "ERROR: app record not found for $APP_BUNDLE_ID (create it in App Store Connect web UI first)" >&2
        exit 1
    fi
    build_id=$(api_get "builds?filter%5Bapp%5D=${app_id}&sort=-uploadedDate" | jq -r '.data[0].id // empty')
    if [[ -z "$build_id" ]]; then
        echo "ERROR: no build found for $APP_BUNDLE_ID. Run: release.sh upload" >&2
        exit 1
    fi
    echo "Latest build: $build_id"

    # Existing submission?
    local existing
    existing=$(api_get "builds/$build_id/betaAppReviewSubmission" | jq -r '.data.id // empty')
    if [[ -n "$existing" ]]; then
        echo "Already submitted for review: $existing"
        api_get "betaAppReviewSubmissions/$existing" | jq -r '.data.attributes.betaReviewState // empty'
        return
    fi

    # Beta App Localization (description, feedback email, marketing + privacy URLs)
    local localization
    localization=$(api_get "apps/$app_id/betaAppLocalizations" | jq -r '.data[0].id // empty')
    if [[ -z "$localization" ]]; then
        local resp
        resp=$(api_post "betaAppLocalizations" "$(jq -n --arg app "$app_id" \
            --arg desc "$BETA_APP_DESCRIPTION" \
            --arg email "$BETA_APP_FEEDBACK_EMAIL" \
            --arg murl "$BETA_APP_MARKETING_URL" \
            --arg purl "$BETA_APP_PRIVACY_POLICY_URL" \
            '{data:{type:"betaAppLocalizations",attributes:{description:$desc,locale:"en-GB",feedbackEmail:$email,marketingUrl:$murl,privacyPolicyUrl:$purl},relationships:{app:{data:{type:"apps",id:$app}}}}}')")
        localization=$(echo "$resp" | jq -r '.data.id // empty')
        if [[ -z "$localization" ]]; then
            echo "ERROR: betaAppLocalizations creation failed: $(echo "$resp" | jq -r '.errors[0].detail // "unknown"')" >&2
            exit 1
        fi
        echo "Created betaAppLocalizations $localization"
    else
        echo "Existing betaAppLocalizations $localization"
        local cur
        cur=$(api_get "betaAppLocalizations/$localization")
        local need_urls
        need_urls=$(echo "$cur" | jq -r '.data.attributes | select(.marketingUrl == null or .marketingUrl == "" or .marketingUrl == "http://example.com" or .privacyPolicyUrl == null or .privacyPolicyUrl == "" or .privacyPolicyUrl == "http://example.com") | "missing"')
        if [[ -n "$need_urls" ]]; then
            echo "Filling in marketing + privacy URLs"
            api_patch "betaAppLocalizations/$localization" "$(jq -n --arg id "$localization" \
                --arg murl "$BETA_APP_MARKETING_URL" \
                --arg purl "$BETA_APP_PRIVACY_POLICY_URL" \
                '{data:{type:"betaAppLocalizations",id:$id,attributes:{marketingUrl:$murl,privacyPolicyUrl:$purl}}}')" \
                | jq -r '"marketingUrl: \(.data.attributes.marketingUrl), privacyPolicyUrl: \(.data.attributes.privacyPolicyUrl)"'
        fi
    fi

    # Beta App Review Details (contact info required for external testing)
    local review_detail
    review_detail=$(api_get "betaAppReviewDetails?filter%5Bapp%5D=${app_id}" | jq -r '.data[0].id // empty')
    if [[ -n "$review_detail" ]]; then
        local missing
        missing=$(api_get "betaAppReviewDetails/$review_detail" | jq -r '.data.attributes | select(.contactFirstName == null or .contactLastName == null or .contactEmail == null or .contactPhone == null) | "missing"' )
        if [[ -n "$missing" ]]; then
            echo "Filling in Beta App Review contact info"
            api_patch "betaAppReviewDetails/$review_detail" "$(jq -n --arg f "$BETA_REVIEW_FIRST_NAME" --arg l "$BETA_REVIEW_LAST_NAME" \
                --arg p "$BETA_REVIEW_PHONE" --arg e "$BETA_REVIEW_EMAIL" \
                '{data:{type:"betaAppReviewDetails",id:$review_detail,attributes:{contactFirstName:$f,contactLastName:$l,contactPhone:$p,contactEmail:$e,demoAccountRequired:false}}}')" >/dev/null
        fi
    else
        echo "ERROR: no betaAppReviewDetails for app $app_id" >&2
        exit 1
    fi

    # Submit
    local resp
    resp=$(api_post "betaAppReviewSubmissions" "$(jq -n --arg b "$build_id" \
        '{data:{type:"betaAppReviewSubmissions",relationships:{build:{data:{type:"builds",id:$b}}}}}')")
    local sub_id state
    sub_id=$(echo "$resp" | jq -r '.data.id // empty')
    state=$(echo "$resp" | jq -r '.data.attributes.betaReviewState // empty')
    if [[ -z "$sub_id" ]]; then
        echo "ERROR: submission failed: $(echo "$resp" | jq -r '.errors[0].detail // "unknown"')" >&2
        exit 1
    fi
    echo "Submitted $sub_id ($state)"
}

run_step() {
    case "$1" in
        register-bundle) register_bundle ;;
        cert) cert ;;
        profile) profile ;;
        archive) archive ;;
        export) export_ipa ;;
        upload) upload ;;
        whats-new) whats_new ;;
        groups) groups ;;
        submit) submit ;;
        all) register_bundle; cert; profile; archive; export_ipa; upload; whats_new; groups; submit ;;
        *) echo "Unknown step: $1" >&2; usage; exit 1 ;;
    esac
}

for step in "${WANTED_STEPS[@]}"; do
    run_step "$step"
done

echo -e "\nDone."

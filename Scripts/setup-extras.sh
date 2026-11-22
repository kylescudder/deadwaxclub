# Deadwax-only setup steps, sourced by setup.sh after the iOS secrets.

if [[ ! -f Site/public/js/config.js ]]; then
    cp Site/public/js/config.example.js Site/public/js/config.js
    ok "Created Site/public/js/config.js for the local list viewer"
else
    ok "Site/public/js/config.js already exists"
fi
note "Universal Links also need the Apple Team ID in Site/public/.well-known/apple-app-site-association."

const fs = require("fs");

module.exports = {
  flowFile: "flows.json",
  flowFilePretty: true,
  uiPort: process.env.PORT || 1880,
  // Set explicitly (from sops) so the flows' credentials decrypt with a known
  // key rather than a system-generated one.
  credentialSecret: fs
    .readFileSync(process.env.NODE_RED_CREDENTIAL_SECRET_FILE, "utf8")
    .trim(),
  diagnostics: {
    enabled: true,
    ui: true,
  },
  runtimeState: {
    enabled: false,
    ui: false,
  },
  logging: {
    console: {
      level: "warn",
      metrics: false,
      audit: false,
    },
  },
  exportGlobalContextKeys: false,
  externalModules: {},
  editorTheme: {
    palette: {},
    projects: {
      enabled: false,
      workflow: {
        mode: "manual",
      },
    },
    codeEditor: {
      lib: "monaco",
      options: {},
    },
    markdownEditor: {
      mermaid: {
        enabled: true,
      },
    },
  },
  functionExternalModules: true,
  functionTimeout: 0,
  functionGlobalContext: {},
  debugMaxLength: 1000,
  mqttReconnectTime: 15000,
  serialReconnectTime: 15000,
  // Admin login via Kanidm OIDC (passport-openidconnect). The client secret is
  // read from a sops-installed file at startup.
  adminAuth: {
    type: "strategy",
    strategy: {
      name: "openidconnect",
      label: "Sign in with Kanidm",
      icon: "fa-cloud",
      strategy: require("passport-openidconnect").Strategy,
      options: {
        // URLs come from the unit environment (set from the active env) so this
        // file needs no per-env fork. See guests/node-red/default.nix.
        issuer: `${process.env.NODE_RED_IDM_URL}/oauth2/openid/node-red`,
        authorizationURL: `${process.env.NODE_RED_IDM_URL}/ui/oauth2`,
        tokenURL: `${process.env.NODE_RED_IDM_URL}/oauth2/token`,
        userInfoURL: `${process.env.NODE_RED_IDM_URL}/oauth2/openid/node-red/userinfo`,
        clientID: "node-red",
        clientSecret: fs
          .readFileSync(process.env.NODE_RED_OIDC_SECRET_FILE, "utf8")
          .trim(),
        callbackURL: `${process.env.NODE_RED_PUBLIC_URL}/auth/strategy/callback/`,
        scope: ["email", "profile", "openid"],
        proxy: true,
        verify: function (issuer, profile, done) {
          done(null, profile);
        },
      },
    },
    users: function (user) {
      return Promise.resolve({ username: user, permissions: "*" });
    },
  },
};

#!/usr/bin/env ruby
# frozen_string_literal: true

# Enables Sign in with Apple, as a primary App ID, on an existing App ID so a
# Services ID can group with it for the web flow, then lists the App ID's
# provisioning profiles and their state. Idempotent; prints no credentials.
#   BUNDLE_ID=com.justspeaktoit.mac APP_STORE_CONNECT_KEY_ID=... \
#   APP_STORE_CONNECT_ISSUER_ID=... APP_STORE_CONNECT_KEY_PATH=... \
#   ruby scripts/enable-sign-in-with-apple.rb

require_relative "create-ios-app-store-profile"

module SignInWithApple
  CAPABILITY = "APPLE_ID_AUTH"

  def self.enable(client:, bundle_id:, log: ->(message) { puts message })
    escaped = URI.encode_www_form_component(bundle_id)
    bundles = client.list("/v1/bundleIds?filter%5Bidentifier%5D=#{escaped}&limit=200")
      .select { |bundle| bundle.dig("attributes", "identifier") == bundle_id }
    raise IOSProfileBootstrap::ValidationError, "Expected one App ID #{bundle_id}, found #{bundles.length}" unless bundles.length == 1

    bundle_resource_id = bundles.first.fetch("id")
    existing = client.list("/v1/bundleIds/#{bundle_resource_id}/bundleIdCapabilities")
      .find { |capability| capability.dig("attributes", "capabilityType") == CAPABILITY }
    if existing
      consent = Array(existing.dig("attributes", "settings"))
        .find { |setting| setting["key"] == "APPLE_ID_AUTH_APP_CONSENT" }
      options = Array(consent&.fetch("options", nil)).map { |option| option["key"] }
      unless options.include?("PRIMARY_APP_CONSENT")
        raise IOSProfileBootstrap::ValidationError,
              "Sign in with Apple on #{bundle_id} is not configured as a primary App ID (#{options.join(', ')}). " \
              "In the Apple Developer portal, set it to \"Enable as a primary App ID\", then rerun."
      end
      log.call("- Sign in with Apple was already enabled on #{bundle_id} as a primary App ID")
    else
      client.post("/v1/bundleIdCapabilities", {
        data: {
          type: "bundleIdCapabilities",
          attributes: {
            capabilityType: CAPABILITY,
            settings: [{ key: "APPLE_ID_AUTH_APP_CONSENT", options: [{ key: "PRIMARY_APP_CONSENT" }] }],
          },
          relationships: { bundleId: { data: { type: "bundleIds", id: bundle_resource_id } } },
        },
      })
      log.call("- Enabled Sign in with Apple (primary App ID) on #{bundle_id}")
    end
    profiles = client.list("/v1/bundleIds/#{bundle_resource_id}/profiles?limit=200")
    log.call("- #{bundle_id} has no provisioning profiles") if profiles.empty?
    profiles.each do |profile|
      attributes = profile.fetch("attributes")
      log.call("- Profile #{attributes['name']}: #{attributes['profileType']}, #{attributes['profileState']}")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    token = IOSProfileBootstrap.jwt_token(key_id: ENV.fetch("APP_STORE_CONNECT_KEY_ID"),
                                          issuer_id: ENV.fetch("APP_STORE_CONNECT_ISSUER_ID"),
                                          private_key: OpenSSL::PKey::EC.new(File.read(ENV.fetch("APP_STORE_CONNECT_KEY_PATH"))))
    transport = IOSProfileBootstrap::HttpTransport.new(api_base: "https://api.appstoreconnect.apple.com", token: token)
    SignInWithApple.enable(client: IOSProfileBootstrap::Client.new(transport: transport), bundle_id: ENV.fetch("BUNDLE_ID"))
  rescue IOSProfileBootstrap::ApiError, IOSProfileBootstrap::ValidationError => error
    abort(error.message)
  end
end

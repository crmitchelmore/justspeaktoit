#!/usr/bin/env ruby
# frozen_string_literal: true

# Fetches a usable iOS App Store provisioning profile for an existing App ID
# through the App Store Connect API at build time, so capability changes in the
# Apple Developer portal never need a manual profile download (#1119).
#
# A profile is usable when it is ACTIVE, IOS_APP_STORE, includes the
# distribution certificate being imported (matched by serial) and carries every
# required and preferred entitlement value, with no extra values under an
# --exact key. Otherwise this run's own profile
# (named "<bundle id> App Store <serial suffix>") is deleted if present and
# created again, which picks up the App ID's current capabilities. A freshly
# created profile must carry every required value; a missing preferred value
# only warns. Profiles this script did not name are never deleted. A
# concurrent refresh of the same profile (404 on delete, 409 on create) is
# resolved by searching again.
#
# Never prints profile content. Run with:
#   APP_STORE_CONNECT_KEY_ID=... APP_STORE_CONNECT_ISSUER_ID=... \
#   APP_STORE_CONNECT_KEY_PATH=... ruby scripts/ensure-ios-app-store-profile.rb \
#     --bundle-id com.example.app --certificate-serial 0123 \
#     --require com.apple.security.application-groups=group.com.example \
#     --prefer com.apple.developer.icloud-container-identifiers=iCloud.com.example \
#     --output app.mobileprovision

require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "rexml/document"
require "uri"
require_relative "create-ios-app-store-profile"

module IOSProfileEnsure
  ValidationError = IOSProfileBootstrap::ValidationError
  ApiError = IOSProfileBootstrap::ApiError

  # Reads the entitlements from a CMS-signed provisioning profile. The signed
  # payload is an uncompressed XML plist, so it can be sliced out of the DER
  # bytes without verifying the signature (Apple has just served it over TLS).
  module ProfileEntitlements
    def self.parse(der)
      bytes = der.dup.force_encoding(Encoding::BINARY)
      start = bytes.index("<?xml")
      finish = bytes.index("</plist>")
      raise ValidationError, "Provisioning profile has no embedded property list" unless start && finish

      xml = bytes[start...(finish + "</plist>".length)].force_encoding(Encoding::UTF_8)
      root = REXML::Document.new(xml).root
      value = plist_value(root.elements[1])
      raise ValidationError, "Provisioning profile has no Entitlements" unless value.is_a?(Hash) && value["Entitlements"]

      value
    end

    def self.plist_value(element)
      case element.name
      when "dict"
        children = element.elements.to_a
        children.each_slice(2).to_h { |key, value| [key.text.to_s, plist_value(value)] }
      when "array" then element.elements.map { |child| plist_value(child) }
      when "true" then true
      when "false" then false
      when "integer" then element.text.to_i
      else element.text.to_s
      end
    end
  end

  class Ensurer
    def initialize(client:, bundle_id:, certificate_serial:, required: {}, preferred: {}, exact: [],
                   logger: ->(message) { puts message }, warner: ->(message) { warn message },
                   sleeper: ->(seconds) { sleep(seconds) })
      @client = client
      @bundle_id = bundle_id
      @certificate_serial = certificate_serial
      @required = required
      @preferred = preferred
      @exact = exact
      @sleeper = sleeper
      @logger = logger
      @warner = warner
    end

    def normalized_serial
      @certificate_serial.delete(":").upcase.sub(/^0+/, "")
    end

    def profile_name
      "#{@bundle_id} App Store #{normalized_serial[-8, 8]}"
    end

    # Returns the decoded profile bytes.
    def ensure_profile
      attempt(retry_conflict: true)
    end

    private

    def attempt(retry_conflict:)
      bundle_resource_id = fetch_bundle.fetch("id")
      certificate_id = find_certificate.fetch("id")
      candidates = @client.list("/v1/bundleIds/#{bundle_resource_id}/profiles?limit=200")
        .select { |profile| profile.dig("attributes", "profileType") == "IOS_APP_STORE" }
      usable = candidates
        .select { |profile| profile.dig("attributes", "profileState") == "ACTIVE" }
        .sort_by { |profile| profile.dig("attributes", "name") == profile_name ? 0 : 1 }
        .find { |profile| usable?(profile, certificate_id) }
      if usable
        @logger.call("Reusing provisioning profile #{usable.dig('attributes', 'name')} for #{@bundle_id}")
        return decode(usable)
      end

      candidates.select { |profile| profile.dig("attributes", "name") == profile_name }.each do |stale|
        @logger.call("Deleting #{stale.dig('attributes', 'profileState')} provisioning profile #{profile_name}")
        delete_profile(stale)
      end
      begin
        created = create_profile(bundle_resource_id, certificate_id)
      rescue IOSProfileBootstrap::ConflictError
        raise unless retry_conflict

        @logger.call("Provisioning profile #{profile_name} was created concurrently; searching again")
        @sleeper.call(5)
        return attempt(retry_conflict: false)
      end
      der = decode(created)
      entitlements = ProfileEntitlements.parse(der).fetch("Entitlements")
      mismatches = missing(entitlements, @required).map { |entry| "lacks #{entry}" } + extra(entitlements)
      unless mismatches.empty?
        raise ValidationError,
              "The new provisioning profile for #{@bundle_id} #{mismatches.join('; ')}. " \
              "Match the App ID's capabilities in the Apple Developer portal, then rerun this workflow."
      end
      missing(entitlements, @preferred).each do |entry|
        @warner.call("Provisioning profile for #{@bundle_id} lacks preferred #{entry}")
      end
      @logger.call("Created provisioning profile #{profile_name} for #{@bundle_id}")
      der
    end

    def fetch_bundle
      escaped = URI.encode_www_form_component(@bundle_id)
      matches = @client.list("/v1/bundleIds?filter%5Bidentifier%5D=#{escaped}&limit=200")
        .select { |bundle| bundle.dig("attributes", "identifier") == @bundle_id }
      raise ValidationError, "App ID #{@bundle_id} is not registered" if matches.empty?
      raise ValidationError, "Multiple registered App IDs found for #{@bundle_id}" if matches.length > 1

      matches.first
    end

    def find_certificate
      certificates = @client.list("/v1/certificates?filter%5BcertificateType%5D=DISTRIBUTION,IOS_DISTRIBUTION&limit=200")
      certificate = certificates.find do |candidate|
        candidate.dig("attributes", "serialNumber").to_s.delete(":").upcase.sub(/^0+/, "") == normalized_serial
      end
      raise ValidationError, "No Apple distribution certificate matched serial #{@certificate_serial}" unless certificate

      certificate
    end

    def usable?(profile, certificate_id)
      detail = @client.get("/v1/profiles/#{profile.fetch('id')}?include=certificates").fetch("data")
      certificate_ids = Array(detail.dig("relationships", "certificates", "data")).map { |entry| entry["id"] }
      return false unless certificate_ids.include?(certificate_id)

      entitlements = ProfileEntitlements.parse(decode(profile)).fetch("Entitlements")
      gaps = missing(entitlements, @required) + missing(entitlements, @preferred) + extra(entitlements)
      @logger.call("Profile #{profile.dig('attributes', 'name')} lacks #{gaps.join(', ')}") unless gaps.empty?
      gaps.empty?
    rescue ValidationError
      false
    end

    def create_profile(bundle_resource_id, certificate_id)
      body = {
        data: {
          type: "profiles",
          attributes: { name: profile_name, profileType: "IOS_APP_STORE" },
          relationships: {
            bundleId: { data: { type: "bundleIds", id: bundle_resource_id } },
            certificates: { data: [{ type: "certificates", id: certificate_id }] },
          },
        },
      }
      @client.post("/v1/profiles", body).fetch("data")
    end

    def delete_profile(profile)
      @client.request(method: Net::HTTP::Delete, path: "/v1/profiles/#{profile.fetch('id')}")
    rescue ApiError => error
      raise unless error.status == 404

      @logger.call("Provisioning profile #{profile_name} was already deleted")
    end

    def decode(profile)
      content = profile.dig("attributes", "profileContent")
      content ||= @client.get("/v1/profiles/#{profile.fetch('id')}").dig("data", "attributes", "profileContent")
      raise ValidationError, "Apple returned a profile without profileContent" unless content

      Base64.decode64(content)
    end

    # Values under an --exact key that no expectation asked for.
    def extra(entitlements)
      @exact.flat_map do |key|
        allowed = Array(@required[key]) + Array(@preferred[key])
        Array(entitlements[key]).reject { |value| allowed.include?(value) }.map { |value| "has unexpected #{key}=#{value}" }
      end
    end

    def missing(entitlements, expectations)
      expectations.flat_map do |key, values|
        present = Array(entitlements[key])
        values.reject { |value| present.include?(value) }.map { |value| "#{key}=#{value}" }
      end
    end
  end

  def self.parse_expectation(value, into)
    key, expected = value.split("=", 2)
    abort("Expected KEY=VALUE, got #{value}") if key.to_s.empty? || expected.to_s.empty?
    (into[key] ||= []) << expected
  end

  def self.main(argv)
    options = { required: {}, preferred: {}, exact: [] }
    OptionParser.new do |parser|
      parser.on("--bundle-id IDENTIFIER") { |value| options[:bundle_id] = value }
      parser.on("--certificate-serial SERIAL") { |value| options[:certificate_serial] = value }
      parser.on("--require KEY=VALUE") { |value| parse_expectation(value, options[:required]) }
      parser.on("--prefer KEY=VALUE") { |value| parse_expectation(value, options[:preferred]) }
      parser.on("--exact KEY") { |value| options[:exact] << value }
      parser.on("--output PATH") { |value| options[:output] = value }
    end.parse!(argv)
    missing_options = %i[bundle_id certificate_serial output].reject { |key| options[key] && !options[key].empty? }
    abort("Missing required options: #{missing_options.join(', ')}") unless missing_options.empty?

    private_key = OpenSSL::PKey::EC.new(File.read(ENV.fetch("APP_STORE_CONNECT_KEY_PATH")))
    token = IOSProfileBootstrap.jwt_token(key_id: ENV.fetch("APP_STORE_CONNECT_KEY_ID"),
                                          issuer_id: ENV.fetch("APP_STORE_CONNECT_ISSUER_ID"),
                                          private_key: private_key)
    transport = IOSProfileBootstrap::HttpTransport.new(api_base: "https://api.appstoreconnect.apple.com", token: token)
    ensurer = Ensurer.new(client: IOSProfileBootstrap::Client.new(transport: transport),
                          bundle_id: options[:bundle_id], certificate_serial: options[:certificate_serial],
                          required: options[:required], preferred: options[:preferred],
                          exact: options[:exact])
    File.binwrite(options[:output], ensurer.ensure_profile)
  rescue ApiError, ValidationError => error
    abort(error.message)
  end
end

IOSProfileEnsure.main(ARGV) if $PROGRAM_NAME == __FILE__

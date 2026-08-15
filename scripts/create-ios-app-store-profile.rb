#!/usr/bin/env ruby
# frozen_string_literal: true

# Ensures the App Store Connect bundle ID, capabilities and App Store
# provisioning profile exist for an iOS target, then writes the profile to
# disk. Safe to run concurrently: create conflicts (HTTP 409) from overlapping
# workers or manual portal edits are resolved by re-fetching the canonical
# resource with bounded, jittered retries and validating it matches the
# requested bundle, capability, certificate and active state. Authentication,
# entitlement and validation failures are never retried as conflicts.

require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "uri"

module IOSProfileBootstrap
  class ApiError < StandardError
    attr_reader :status, :body

    def initialize(message, status: nil, body: nil)
      super(message)
      @status = status
      @body = body
    end
  end

  # Raised only for HTTP 409: the resource we tried to create already exists
  # (typically because a concurrent worker or manual portal edit created it).
  class ConflictError < ApiError; end

  # Raised when a fetched resource does not match what was requested, or a
  # duplicate-reported resource never becomes visible. Never retried.
  class ValidationError < StandardError; end

  def self.base64url(value)
    Base64.urlsafe_encode64(value, padding: false)
  end

  def self.jwt_token(key_id:, issuer_id:, private_key:, now: Time.now)
    header = base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
    issued_at = now.to_i
    payload = base64url(JSON.generate(iss: issuer_id, iat: issued_at, exp: issued_at + 1_200, aud: "appstoreconnect-v1"))
    unsigned_token = "#{header}.#{payload}"
    der_signature = private_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(unsigned_token))
    sequence = OpenSSL::ASN1.decode(der_signature)
    raw_signature = sequence.value.map { |integer| integer.value.to_s(2).rjust(32, "\0") }.join
    "#{unsigned_token}.#{base64url(raw_signature)}"
  end

  # Thin transport: performs one HTTPS request and returns [status, raw_body].
  # Tests substitute any object responding to call(method:, path:, body:).
  class HttpTransport
    def initialize(api_base:, token:)
      @api_base = api_base
      @token = token
    end

    def call(method:, path:, body: nil)
      uri = URI.join(@api_base, path)
      request = method.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
      [Integer(response.code), response.body]
    end
  end

  # Classifies responses: 2xx parses and returns JSON, 409 raises
  # ConflictError, anything else raises ApiError (including 401/403 auth and
  # 400 validation failures, which callers must not treat as conflicts).
  class Client
    def initialize(transport:)
      @transport = transport
    end

    def request(method:, path:, body: nil)
      status, raw = @transport.call(method: method, path: path, body: body)
      if (200..299).cover?(status)
        return nil if raw.nil? || raw.empty?

        return JSON.parse(raw)
      end

      message = "App Store Connect API #{method::METHOD} #{path} failed (#{status}): #{raw}"
      raise ConflictError.new(message, status: status, body: raw) if status == 409

      raise ApiError.new(message, status: status, body: raw)
    end

    def get(path)
      request(method: Net::HTTP::Get, path: path)
    end

    def post(path, body)
      request(method: Net::HTTP::Post, path: path, body: body)
    end

    def list(path)
      get(path).fetch("data")
    end
  end

  class Provisioner
    DEFAULT_MAX_ATTEMPTS = 5
    BASE_DELAY_SECONDS = 2.0

    def initialize(client:, bundle_id:, profile_name:, certificate_serial:, bundle_name: nil, capabilities: [],
                   max_attempts: DEFAULT_MAX_ATTEMPTS, sleeper: ->(seconds) { sleep(seconds) },
                   jitter: -> { rand }, logger: ->(message) { puts message })
      @client = client
      @bundle_id = bundle_id
      @bundle_name = bundle_name || bundle_id
      @capabilities = capabilities
      @certificate_serial = certificate_serial
      @base_profile_name = profile_name
      @max_attempts = max_attempts
      @sleeper = sleeper
      @jitter = jitter
      @logger = logger
    end

    # Returns the base64 profileContent for the ensured profile.
    def provision
      bundle = ensure_bundle_id
      bundle_resource_id = bundle.fetch("id")
      ensure_capabilities(bundle_resource_id)
      certificate = find_certificate
      profile = ensure_profile(bundle_resource_id, certificate.fetch("id"))
      profile_content(profile)
    end

    def normalized_serial
      @certificate_serial.delete(":").upcase.sub(/^0+/, "")
    end

    def profile_name
      "#{@base_profile_name} #{normalized_serial[-8, 8]}"
    end

    private

    def log(message)
      @logger.call(message)
    end

    def ensure_bundle_id
      bundle = fetch_bundle
      if bundle
        log "Reusing bundle ID #{@bundle_id}"
        return validate_bundle!(bundle)
      end

      create_body = {
        data: {
          type: "bundleIds",
          attributes: {
            identifier: @bundle_id,
            name: @bundle_name,
            platform: "IOS",
          },
        },
      }
      begin
        created = @client.post("/v1/bundleIds", create_body).fetch("data")
        log "Registered bundle ID #{@bundle_id}"
        validate_bundle!(created)
      rescue ConflictError
        log "Bundle ID #{@bundle_id} already exists (created concurrently); re-fetching"
        validate_bundle!(refetch("Bundle ID #{@bundle_id}") { fetch_bundle })
      end
    end

    def fetch_bundle
      escaped_bundle_id = URI.encode_www_form_component(@bundle_id)
      bundles = @client.list("/v1/bundleIds?filter%5Bidentifier%5D=#{escaped_bundle_id}")
      # The identifier filter matches substrings, so keep only exact matches.
      matches = bundles.select { |candidate| candidate.dig("attributes", "identifier") == @bundle_id }
      raise ValidationError, "Multiple registered bundle IDs found for #{@bundle_id}" if matches.length > 1

      matches.first
    end

    def validate_bundle!(bundle)
      identifier = bundle.dig("attributes", "identifier")
      unless identifier == @bundle_id
        raise ValidationError,
              "Bundle ID resource #{bundle['id']} has identifier '#{identifier}', expected '#{@bundle_id}'. " \
              "Check the App Store Connect portal for a conflicting registration."
      end

      bundle
    end

    def ensure_capabilities(bundle_resource_id)
      return if @capabilities.empty?

      enabled = enabled_capabilities(bundle_resource_id)
      @capabilities.uniq.each do |capability_type|
        if enabled.include?(capability_type)
          log "Reusing #{capability_type} capability for #{@bundle_id}"
          next
        end

        create_body = {
          data: {
            type: "bundleIdCapabilities",
            attributes: {
              capabilityType: capability_type,
            },
            relationships: {
              bundleId: {
                data: { type: "bundleIds", id: bundle_resource_id },
              },
            },
          },
        }
        begin
          @client.post("/v1/bundleIdCapabilities", create_body)
          log "Enabled #{capability_type} capability for #{@bundle_id}"
        rescue ConflictError
          log "#{capability_type} capability already enabled (created concurrently); re-checking"
          refetch("#{capability_type} capability for #{@bundle_id}") do
            enabled_capabilities(bundle_resource_id).include?(capability_type) ? capability_type : nil
          end
        end
      end
    end

    def enabled_capabilities(bundle_resource_id)
      capabilities = @client.list("/v1/bundleIds/#{bundle_resource_id}/bundleIdCapabilities")
      capabilities.map { |capability| capability.dig("attributes", "capabilityType") }.compact
    end

    def find_certificate
      certificates = @client.list("/v1/certificates?filter%5BcertificateType%5D=DISTRIBUTION,IOS_DISTRIBUTION&limit=200")
      certificate = certificates.find do |candidate|
        candidate_serial = candidate.dig("attributes", "serialNumber").to_s.delete(":").upcase.sub(/^0+/, "")
        candidate_serial == normalized_serial
      end
      unless certificate
        raise ValidationError, "No Apple distribution certificate matched serial #{@certificate_serial}"
      end

      certificate
    end

    def ensure_profile(bundle_resource_id, certificate_id)
      profile = fetch_active_profile
      if profile
        log "Reusing provisioning profile #{profile_name}"
        return validate_profile!(profile, bundle_resource_id, certificate_id)
      end

      create_body = {
        data: {
          type: "profiles",
          attributes: {
            name: profile_name,
            profileType: "IOS_APP_STORE",
          },
          relationships: {
            bundleId: {
              data: { type: "bundleIds", id: bundle_resource_id },
            },
            certificates: {
              data: [{ type: "certificates", id: certificate_id }],
            },
          },
        },
      }
      begin
        created = @client.post("/v1/profiles", create_body).fetch("data")
        log "Created provisioning profile #{profile_name}"
        validate_profile!(created, bundle_resource_id, certificate_id)
      rescue ConflictError
        log "Provisioning profile #{profile_name} already exists (created concurrently); re-fetching"
        profile = refetch("Provisioning profile #{profile_name}") { fetch_active_profile }
        validate_profile!(profile, bundle_resource_id, certificate_id)
      end
    end

    def fetch_active_profile
      escaped_profile_name = URI.encode_www_form_component(profile_name)
      profiles = @client.list("/v1/profiles?filter%5Bname%5D=#{escaped_profile_name}&limit=200")
      profiles.find do |candidate|
        candidate.dig("attributes", "name") == profile_name &&
          candidate.dig("attributes", "profileState") == "ACTIVE"
      end
    end

    # Fetches the canonical profile record and verifies it matches what this
    # run requested. A mismatched profile is a genuine configuration problem
    # (e.g. a stale profile left over from a certificate rotation) and must
    # fail loudly rather than be silently reused.
    def validate_profile!(profile, bundle_resource_id, certificate_id)
      profile_id = profile.fetch("id")
      detail = @client.get("/v1/profiles/#{profile_id}?include=bundleId,certificates").fetch("data")

      state = detail.dig("attributes", "profileState")
      unless state == "ACTIVE"
        raise ValidationError,
              "Provisioning profile #{profile_name} (#{profile_id}) is #{state || 'in an unknown state'}, expected ACTIVE. " \
              "Delete or regenerate it in the Apple Developer portal, then rerun this workflow."
      end

      linked_bundle_id = detail.dig("relationships", "bundleId", "data", "id")
      unless linked_bundle_id == bundle_resource_id
        raise ValidationError,
              "Provisioning profile #{profile_name} (#{profile_id}) is linked to bundle ID resource " \
              "#{linked_bundle_id || 'none'}, expected #{bundle_resource_id} (#{@bundle_id}). " \
              "Delete the stale profile in the Apple Developer portal, then rerun this workflow."
      end

      linked_certificate_ids = Array(detail.dig("relationships", "certificates", "data")).map { |entry| entry["id"] }
      unless linked_certificate_ids.include?(certificate_id)
        raise ValidationError,
              "Provisioning profile #{profile_name} (#{profile_id}) does not include distribution certificate " \
              "#{certificate_id} (serial #{@certificate_serial}). " \
              "Delete the stale profile in the Apple Developer portal, then rerun this workflow."
      end

      detail
    end

    def profile_content(profile)
      content = profile.dig("attributes", "profileContent")
      unless content
        content = @client.get("/v1/profiles/#{profile.fetch('id')}").dig("data", "attributes", "profileContent")
      end
      raise ValidationError, "Apple returned a profile without profileContent" unless content

      content
    end

    # Bounded, jittered polling for a resource that App Store Connect reported
    # as a duplicate but which may not be list-visible yet (read-after-write
    # consistency lag). Only used after a ConflictError.
    def refetch(description)
      attempt = 0
      loop do
        attempt += 1
        resource = yield
        return resource if resource

        if attempt >= @max_attempts
          raise ValidationError,
                "#{description} was reported as a duplicate by App Store Connect but did not become visible " \
                "after #{@max_attempts} attempts. Check the Apple Developer portal and rerun this workflow."
        end

        delay = BASE_DELAY_SECONDS * attempt + @jitter.call
        log "#{description} not visible yet (attempt #{attempt}/#{@max_attempts}); retrying in #{delay.round(1)}s"
        @sleeper.call(delay)
      end
    end
  end

  def self.parse_options(argv)
    options = {
      api_base: "https://api.appstoreconnect.apple.com",
      capabilities: [],
    }

    OptionParser.new do |parser|
      parser.on("--bundle-id IDENTIFIER") { |value| options[:bundle_id] = value }
      parser.on("--bundle-name NAME") { |value| options[:bundle_name] = value }
      parser.on("--capability TYPE") { |value| options[:capabilities] << value }
      parser.on("--certificate-serial SERIAL") { |value| options[:certificate_serial] = value }
      parser.on("--profile-name NAME") { |value| options[:profile_name] = value }
      parser.on("--output PATH") { |value| options[:output] = value }
    end.parse!(argv)

    required_options = %i[bundle_id certificate_serial profile_name output]
    missing_options = required_options.reject { |key| options[key] && !options[key].empty? }
    abort("Missing required options: #{missing_options.join(', ')}") unless missing_options.empty?

    options
  end

  def self.main(argv)
    options = parse_options(argv)

    key_id = ENV.fetch("APP_STORE_CONNECT_KEY_ID")
    issuer_id = ENV.fetch("APP_STORE_CONNECT_ISSUER_ID")
    key_path = ENV.fetch("APP_STORE_CONNECT_KEY_PATH")
    private_key = OpenSSL::PKey::EC.new(File.read(key_path))
    token = jwt_token(key_id: key_id, issuer_id: issuer_id, private_key: private_key)

    transport = HttpTransport.new(api_base: options[:api_base], token: token)
    client = Client.new(transport: transport)
    provisioner = Provisioner.new(
      client: client,
      bundle_id: options[:bundle_id],
      bundle_name: options[:bundle_name],
      capabilities: options[:capabilities],
      certificate_serial: options[:certificate_serial],
      profile_name: options[:profile_name]
    )

    content = provisioner.provision
    File.binwrite(options[:output], Base64.decode64(content))
    puts "Wrote provisioning profile to #{options[:output]}"
  rescue ApiError, ValidationError => error
    abort(error.message)
  end
end

IOSProfileBootstrap.main(ARGV) if $PROGRAM_NAME == __FILE__

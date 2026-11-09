# frozen_string_literal: true

# Tests for scripts/ensure-ios-app-store-profile.rb. No network or credentials.
#   ruby scripts/tests/ensure_ios_app_store_profile_test.rb

require "minitest/autorun"
require_relative "../ensure-ios-app-store-profile"

module IOSProfileEnsure
  class EnsurerTest < Minitest::Test
    class FakeTransport
      Call = Struct.new(:http_method, :path, :body)
      attr_reader :calls

      def initialize(script)
        @script = script.dup
        @calls = []
      end

      def call(method:, path:, body: nil)
        @calls << Call.new(method::METHOD, path, body)
        expected_method, matcher, status, response = @script.shift || raise("Unexpected #{method::METHOD} #{path}")
        raise "Expected #{expected_method} #{matcher}, got #{path}" unless expected_method == method::METHOD && path.include?(matcher)

        [status, response.is_a?(String) ? response : JSON.generate(response)]
      end

      def drained?
        @script.empty?
      end
    end

    BUNDLE_ID = "com.example.app"
    SERIAL = "00AB12CD34EF56789"
    GROUP = "com.apple.security.application-groups"
    ICLOUD = "com.apple.developer.icloud-container-identifiers"

    def profile_der(groups:, containers:)
      strings = ->(values) { values.map { |value| "<string>#{value}</string>" }.join }
      xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Name</key><string>x</string><key>Entitlements</key><dict>
        <key>#{GROUP}</key><array>#{strings.call(groups)}</array>
        <key>#{ICLOUD}</key><array>#{strings.call(containers)}</array>
        <key>get-task-allow</key><false/></dict></dict></plist>
      XML
      "\x30\x82\x01\x00signed#{xml}\x00trailer".b
    end

    def profile(id, name:, state: "ACTIVE", containers: %w[iCloud.legacy], type: "IOS_APP_STORE",
                groups: ["group.example"])
      { "id" => id, "attributes" => {
        "name" => name, "profileState" => state, "profileType" => type,
        "profileContent" => Base64.strict_encode64(profile_der(groups: groups, containers: containers)),
      } }
    end

    def setup_steps
      [
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [{ "id" => "B1", "attributes" => { "identifier" => BUNDLE_ID } }] }],
        ["GET", "/v1/certificates", 200, { "data" => [{ "id" => "C1", "attributes" => { "serialNumber" => SERIAL } }] }],
      ]
    end

    def certificates(id, ids = ["C1"])
      ["GET", "/v1/profiles/#{id}?include=certificates", 200,
       { "data" => { "relationships" => { "certificates" => { "data" => ids.map { |cid| { "id" => cid } } } } } }]
    end

    def ensurer(script, logs = [], warnings = [])
      transport = FakeTransport.new(script)
      [Ensurer.new(client: IOSProfileBootstrap::Client.new(transport: transport), bundle_id: BUNDLE_ID,
                   certificate_serial: SERIAL, required: { GROUP => ["group.example"], ICLOUD => ["iCloud.legacy"] },
                   preferred: { ICLOUD => ["iCloud.shared"] }, exact: [GROUP], logger: ->(m) { logs << m },
                   warner: ->(m) { warnings << m }, sleeper: ->(_seconds) {}), transport]
    end

    def test_profile_name_is_unique_per_bundle_and_certificate
      subject, = ensurer([])
      assert_equal "com.example.app App Store 4EF56789", subject.profile_name
    end

    def test_parses_entitlements_out_of_signed_profile
      entitlements = ProfileEntitlements.parse(profile_der(groups: ["g"], containers: %w[a b])).fetch("Entitlements")
      assert_equal %w[a b], entitlements[ICLOUD]
      assert_equal false, entitlements["get-task-allow"]
    end

    def test_reuses_any_active_profile_with_certificate_and_all_entitlements
      reusable = profile("P2", name: "Owner made", containers: %w[iCloud.legacy iCloud.shared])
      script = setup_steps + [
        ["GET", "/v1/bundleIds/B1/profiles", 200, { "data" => [
          profile("P0", name: "Dev", type: "IOS_APP_DEVELOPMENT"), reusable,
        ] }],
        certificates("P2"),
      ]
      subject, transport = ensurer(script)
      der = subject.ensure_profile
      assert_includes der, "iCloud.shared"
      assert transport.drained?
    end

    def test_replaces_own_invalid_profile_and_skips_profiles_without_the_certificate
      name = ensurer([]).first.profile_name
      script = setup_steps + [
        ["GET", "/v1/bundleIds/B1/profiles", 200, { "data" => [
          profile("P1", name: name, state: "INVALID"),
          profile("P3", name: "Other cert", containers: %w[iCloud.legacy iCloud.shared]),
          profile("P4", name: "Missing shared"),
        ] }],
        certificates("P3", ["C9"]),
        certificates("P4"),
        ["DELETE", "/v1/profiles/P1", 204, ""],
        ["POST", "/v1/profiles", 201, { "data" => profile("P5", name: name, containers: %w[iCloud.legacy iCloud.shared]) }],
      ]
      logs = []
      subject, transport = ensurer(script, logs)
      assert_includes subject.ensure_profile, "iCloud.shared"
      assert transport.drained?
      assert(logs.any? { |log| log.include?("lacks #{ICLOUD}=iCloud.shared") })
      body = transport.calls.last.body
      assert_equal name, body.dig(:data, :attributes, :name)
      assert_equal "C1", body.dig(:data, :relationships, :certificates, :data, 0, :id)
    end

    def test_new_profile_missing_preferred_value_warns
      name = ensurer([]).first.profile_name
      script = setup_steps + [
        ["GET", "/v1/bundleIds/B1/profiles", 200, { "data" => [] }],
        ["POST", "/v1/profiles", 201, { "data" => profile("P5", name: name) }],
      ]
      warnings = []
      subject, = ensurer(script, [], warnings)
      subject.ensure_profile
      assert_equal ["Provisioning profile for #{BUNDLE_ID} lacks preferred #{ICLOUD}=iCloud.shared"], warnings
    end

    def test_new_profile_missing_required_value_fails_with_owner_step
      name = ensurer([]).first.profile_name
      script = setup_steps + [
        ["GET", "/v1/bundleIds/B1/profiles", 200, { "data" => [] }],
        ["POST", "/v1/profiles", 201, { "data" => profile("P5", name: name, containers: []) }],
      ]
      subject, = ensurer(script)
      error = assert_raises(ValidationError) { subject.ensure_profile }
      assert_match(/lacks #{ICLOUD}=iCloud.legacy\. Match the App ID/, error.message)
    end

    def test_skips_profile_with_an_extra_value_under_an_exact_key
      extra = profile("P2", name: "Extra group", containers: %w[iCloud.legacy iCloud.shared],
                            groups: %w[group.example group.other])
      exact = profile("P3", name: "Exact", containers: %w[iCloud.legacy iCloud.shared])
      script = setup_steps + [
        ["GET", "/v1/bundleIds/B1/profiles", 200, { "data" => [extra, exact] }],
        certificates("P2"),
        certificates("P3"),
      ]
      logs = []
      subject, transport = ensurer(script, logs)
      subject.ensure_profile
      assert transport.drained?
      assert(logs.any? { |log| log.include?("has unexpected #{GROUP}=group.other") })
      assert(logs.any? { |log| log.include?("Reusing provisioning profile Exact") })
    end

    def test_concurrent_refresh_converges_on_the_other_runs_profile
      name = ensurer([]).first.profile_name
      fresh = profile("P6", name: name, containers: %w[iCloud.legacy iCloud.shared])
      script = setup_steps + [
        ["GET", "/v1/bundleIds/B1/profiles", 200, { "data" => [profile("P1", name: name, state: "INVALID")] }],
        ["DELETE", "/v1/profiles/P1", 404, { "errors" => [] }],
        ["POST", "/v1/profiles", 409, { "errors" => [] }],
      ] + setup_steps + [
        ["GET", "/v1/bundleIds/B1/profiles", 200, { "data" => [fresh] }],
        certificates("P6"),
      ]
      subject, transport = ensurer(script)
      assert_includes subject.ensure_profile, "iCloud.shared"
      assert transport.drained?
    end

    def test_unregistered_app_id_fails_without_creating_one
      script = [["GET", "/v1/bundleIds?filter", 200, { "data" => [] }]]
      subject, transport = ensurer(script)
      assert_raises(ValidationError) { subject.ensure_profile }
      assert transport.drained?
    end
  end
end

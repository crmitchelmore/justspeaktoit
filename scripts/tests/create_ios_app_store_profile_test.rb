# frozen_string_literal: true

# Tests for scripts/create-ios-app-store-profile.rb conflict handling.
# Self-contained (minitest is in the Ruby standard distribution); no live
# credentials or network access are used. Run with:
#
#   ruby scripts/tests/create_ios_app_store_profile_test.rb

require "minitest/autorun"
require_relative "../create-ios-app-store-profile"

module IOSProfileBootstrap
  # Scripted transport: each expectation is [method, path matcher, status,
  # body]. Requests are matched in order; an unexpected request fails the test.
  class FakeTransport
    Call = Struct.new(:method, :path, :body)

    attr_reader :calls

    def initialize(script)
      @script = script.dup
      @calls = []
    end

    def call(method:, path:, body: nil)
      @calls << Call.new(method::METHOD, path, body)
      expected = @script.shift
      raise "Unexpected request: #{method::METHOD} #{path}" unless expected

      expected_method, matcher, status, response_body = expected
      unless expected_method == method::METHOD && path.include?(matcher)
        raise "Expected #{expected_method} #{matcher}, got #{method::METHOD} #{path}"
      end

      [status, response_body.is_a?(String) ? response_body : JSON.generate(response_body)]
    end

    def drained?
      @script.empty?
    end
  end

  class ProvisionerTest < Minitest::Test
    BUNDLE_ID = "com.example.keyboard"
    BUNDLE_RESOURCE_ID = "B1"
    CERT_ID = "C1"
    CERT_SERIAL = "00AB12CD34EF56789"
    PROFILE_ID = "P1"

    def normalized_serial
      CERT_SERIAL.delete(":").upcase.sub(/^0+/, "")
    end

    def profile_name
      "Example Keyboard App Store #{normalized_serial[-8, 8]}"
    end

    def build_provisioner(script, capabilities: [], max_attempts: 3)
      transport = FakeTransport.new(script)
      @sleeps = []
      provisioner = Provisioner.new(
        client: Client.new(transport: transport),
        bundle_id: BUNDLE_ID,
        bundle_name: "Example Keyboard",
        capabilities: capabilities,
        certificate_serial: CERT_SERIAL,
        profile_name: "Example Keyboard App Store",
        max_attempts: max_attempts,
        sleeper: ->(seconds) { @sleeps << seconds },
        jitter: -> { 0.5 },
        logger: ->(_message) {}
      )
      [provisioner, transport]
    end

    def bundle_resource(id: BUNDLE_RESOURCE_ID, identifier: BUNDLE_ID)
      { "type" => "bundleIds", "id" => id, "attributes" => { "identifier" => identifier } }
    end

    def certificate_resource
      { "type" => "certificates", "id" => CERT_ID, "attributes" => { "serialNumber" => CERT_SERIAL } }
    end

    def profile_resource(id: PROFILE_ID, state: "ACTIVE", content: nil)
      attributes = { "name" => profile_name, "profileState" => state }
      attributes["profileContent"] = content if content
      { "type" => "profiles", "id" => id, "attributes" => attributes }
    end

    def profile_detail(id: PROFILE_ID, state: "ACTIVE", bundle_ref: BUNDLE_RESOURCE_ID, cert_refs: [CERT_ID],
                       content: "UFJPRklMRQ==")
      detail = profile_resource(id: id, state: state, content: content)
      detail["relationships"] = {
        "bundleId" => { "data" => { "type" => "bundleIds", "id" => bundle_ref } },
        "certificates" => { "data" => cert_refs.map { |ref| { "type" => "certificates", "id" => ref } } },
      }
      detail
    end

    def certificate_and_profile_script(profile_steps)
      [["GET", "/v1/certificates", 200, { "data" => [certificate_resource] }]] + profile_steps
    end

    def existing_profile_steps
      [
        ["GET", "/v1/profiles?filter", 200, { "data" => [profile_resource] }],
        ["GET", "/v1/profiles/#{PROFILE_ID}?include=bundleId,certificates", 200, { "data" => profile_detail }],
      ]
    end

    # Acceptance: two workers observing the same missing bundle converge on the
    # same resource. Worker A's create succeeds; worker B receives 409 and must
    # re-fetch worker A's bundle by canonical identifier.
    def test_bundle_create_conflict_converges_on_existing_resource
      script = [
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
        ["POST", "/v1/bundleIds", 409, { "errors" => [{ "status" => "409" }] }],
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [bundle_resource] }],
      ] + certificate_and_profile_script(existing_profile_steps)

      provisioner, transport = build_provisioner(script)
      content = provisioner.provision

      assert_equal "UFJPRklMRQ==", content
      assert transport.drained?
      assert_empty @sleeps
    end

    def test_winning_worker_creates_bundle_without_conflict
      script = [
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
        ["POST", "/v1/bundleIds", 201, { "data" => bundle_resource }],
      ] + certificate_and_profile_script(existing_profile_steps)

      provisioner, transport = build_provisioner(script)
      assert_equal "UFJPRklMRQ==", provisioner.provision
      assert transport.drained?
    end

    # Acceptance: a create conflict followed by delayed list visibility is
    # retried within a bound (with jittered backoff) and succeeds.
    def test_conflict_with_delayed_visibility_retries_within_bound
      script = [
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
        ["POST", "/v1/bundleIds", 409, { "errors" => [] }],
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [bundle_resource] }],
      ] + certificate_and_profile_script(existing_profile_steps)

      provisioner, transport = build_provisioner(script)
      assert_equal "UFJPRklMRQ==", provisioner.provision
      assert transport.drained?
      assert_equal [2.5, 4.5], @sleeps # BASE_DELAY * attempt + jitter(0.5)
    end

    def test_conflict_that_never_becomes_visible_fails_within_bound
      script = [
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
        ["POST", "/v1/bundleIds", 409, { "errors" => [] }],
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
      ]

      provisioner, transport = build_provisioner(script, max_attempts: 3)
      error = assert_raises(ValidationError) { provisioner.provision }
      assert_match(/did not become visible/, error.message)
      assert transport.drained?
      assert_equal 2, @sleeps.length
    end

    # Acceptance: authentication failures are not retried as conflicts.
    def test_auth_failure_is_not_retried_as_conflict
      script = [
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
        ["POST", "/v1/bundleIds", 401, { "errors" => [{ "status" => "401" }] }],
      ]

      provisioner, transport = build_provisioner(script)
      error = assert_raises(ApiError) { provisioner.provision }
      refute_kind_of ConflictError, error
      assert_equal 401, error.status
      assert transport.drained?
      assert_empty @sleeps
    end

    def test_capability_conflict_converges
      script = [
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [bundle_resource] }],
        ["GET", "/v1/bundleIds/#{BUNDLE_RESOURCE_ID}/bundleIdCapabilities", 200, { "data" => [] }],
        ["POST", "/v1/bundleIdCapabilities", 409, { "errors" => [] }],
        ["GET", "/v1/bundleIds/#{BUNDLE_RESOURCE_ID}/bundleIdCapabilities", 200,
         { "data" => [{ "attributes" => { "capabilityType" => "APP_GROUPS" } }] }],
      ] + certificate_and_profile_script(existing_profile_steps)

      provisioner, transport = build_provisioner(script, capabilities: ["APP_GROUPS"])
      assert_equal "UFJPRklMRQ==", provisioner.provision
      assert transport.drained?
    end

    def test_profile_conflict_converges_on_concurrently_created_profile
      profile_steps = [
        ["GET", "/v1/profiles?filter", 200, { "data" => [] }],
        ["POST", "/v1/profiles", 409, { "errors" => [] }],
        ["GET", "/v1/profiles?filter", 200, { "data" => [profile_resource] }],
        ["GET", "/v1/profiles/#{PROFILE_ID}?include=bundleId,certificates", 200, { "data" => profile_detail }],
      ]
      script = [["GET", "/v1/bundleIds?filter", 200, { "data" => [bundle_resource] }]] +
               certificate_and_profile_script(profile_steps)

      provisioner, transport = build_provisioner(script)
      assert_equal "UFJPRklMRQ==", provisioner.provision
      assert transport.drained?
    end

    # Acceptance: a genuine mismatched resource fails with an actionable error
    # rather than being silently reused.
    def test_profile_linked_to_wrong_bundle_fails_with_actionable_error
      profile_steps = [
        ["GET", "/v1/profiles?filter", 200, { "data" => [profile_resource] }],
        ["GET", "/v1/profiles/#{PROFILE_ID}?include=bundleId,certificates", 200,
         { "data" => profile_detail(bundle_ref: "OTHER") }],
      ]
      script = [["GET", "/v1/bundleIds?filter", 200, { "data" => [bundle_resource] }]] +
               certificate_and_profile_script(profile_steps)

      provisioner, transport = build_provisioner(script)
      error = assert_raises(ValidationError) { provisioner.provision }
      assert_match(/linked to bundle ID resource OTHER/, error.message)
      assert_match(/Delete the stale profile/, error.message)
      assert transport.drained?
    end

    def test_profile_missing_certificate_fails_with_actionable_error
      profile_steps = [
        ["GET", "/v1/profiles?filter", 200, { "data" => [profile_resource] }],
        ["GET", "/v1/profiles/#{PROFILE_ID}?include=bundleId,certificates", 200,
         { "data" => profile_detail(cert_refs: ["STALE_CERT"]) }],
      ]
      script = [["GET", "/v1/bundleIds?filter", 200, { "data" => [bundle_resource] }]] +
               certificate_and_profile_script(profile_steps)

      provisioner, transport = build_provisioner(script)
      error = assert_raises(ValidationError) { provisioner.provision }
      assert_match(/does not include distribution certificate #{CERT_ID}/, error.message)
      assert transport.drained?
    end

    def test_refetched_bundle_with_wrong_identifier_fails
      script = [
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [] }],
        ["POST", "/v1/bundleIds", 201, { "data" => bundle_resource(identifier: "com.example.other") }],
      ]

      provisioner, transport = build_provisioner(script)
      error = assert_raises(ValidationError) { provisioner.provision }
      assert_match(/has identifier 'com.example.other'/, error.message)
      assert transport.drained?
    end

    def test_substring_filter_matches_are_ignored
      lookalike = bundle_resource(id: "B9", identifier: "#{BUNDLE_ID}.extension")
      script = [
        ["GET", "/v1/bundleIds?filter", 200, { "data" => [lookalike, bundle_resource] }],
      ] + certificate_and_profile_script(existing_profile_steps)

      provisioner, transport = build_provisioner(script)
      assert_equal "UFJPRklMRQ==", provisioner.provision
      assert transport.drained?
    end
  end
end

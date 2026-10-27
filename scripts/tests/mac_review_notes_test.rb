require 'minitest/autorun'
require 'stringio'
require_relative '../audit-mac-review-notes'

class MacReviewNotesTest < Minitest::Test
  class Client
    attr_reader :calls, :review, :beta_review
    attr_accessor :state, :bundle, :observe_write, :before_second_read, :patch_error, :missing_detail
    attr_accessor :beta_state, :surface
    attr_accessor :before_second_version_read

    def initialize(train: 'stable', surface: 'mac-store')
      @train, @surface = train, surface
      @bundle = "com.justspeaktoit.#{surface == 'ios' ? 'ios' : 'mac.appstore'}#{train == 'alpha' ? '.alpha' : ''}"
      @app = JSON.parse(File.read('Config/ReleasePipeline.json')).fetch('apple').fetch(train).fetch(surface)
      @calls = []
      @state = 'REJECTED'
      @beta_state = 'READY_FOR_BETA_SUBMISSION'
      @observe_write = true
      @detail_reads = 0
      @version_reads = 0
      @review = {'id' => 'version-review', 'type' => 'appStoreReviewDetails', 'attributes' => {
        'notes' => "Owner notes with Unicode café.\n\nDo not replace.\n",
        'contactEmail' => 'private-contact@example.test', 'demoAccountRequired' => true,
        'demoAccountName' => 'private-login', 'demoAccountPassword' => 'private-password'}}
      @beta_review = {'id' => 'beta-review', 'type' => 'betaAppReviewDetails', 'attributes' => {
        'notes' => 'Owner beta instructions', 'contactEmail' => 'private-contact@example.test',
        'contactFirstName' => 'Owner', 'contactLastName' => 'Tester', 'contactPhone' => '+44000000000',
        'demoAccountRequired' => true, 'demoAccountName' => 'private-login', 'demoAccountPassword' => 'private-password'}}
    end

    def version
      {'id' => 'selected-version', 'type' => 'appStoreVersions', 'attributes' => {
        'platform' => surface == 'ios' ? 'IOS' : 'MAC_OS', 'versionString' => '3.2.0', 'appStoreState' => state}}
    end

    def build
      {'id' => 'selected-build', 'attributes' => {'processingState' => 'VALID', 'expired' => false}}
    end

    def get(path)
      calls << [:get, path]
      plain = path.split('?').first
      if plain == "/v1/apps/#{@app}"
        return {'data' => {'id' => @app, 'type' => 'apps', 'attributes' => {'bundleId' => bundle}}}
      end
      if plain == '/v1/appStoreVersions/selected-version/appStoreReviewDetail'
        @detail_reads += 1
        before_second_read&.call(self) if @detail_reads == 2
        return {'data' => nil} if missing_detail
        return {'data' => projection(review)}
      end
      if plain == "/v1/apps/#{@app}/betaAppReviewDetail"
        return {'data' => path.include?('?') ? projection(beta_review) : deep_copy(beta_review)}
      end
      return {'data' => {'id' => 'build-detail', 'attributes' => {
        'externalBuildState' => beta_state, 'autoNotifyEnabled' => true}}} if plain == '/v1/builds/selected-build/buildBetaDetail'
      return {'data' => build} if plain == '/v1/appStoreVersions/selected-version/build'
      return {'data' => {'attributes' => {'state' => 'WAITING_FOR_REVIEW'}}} if plain == '/v1/reviewSubmissions/new-review'
      raise "Unexpected get #{plain}"
    end

    def list(path)
      calls << [:list, path]
      if path.start_with?("/v1/apps/#{@app}/appStoreVersions?")
        @version_reads += 1
        before_second_version_read&.call(self) if @version_reads == 2
        return [deep_copy(version)]
      end
      return [] if path.include?('betaAppReviewSubmission')
      return [build] if path.start_with?('/v1/builds?')
      return [{'id' => 'english', 'attributes' => {'locale' => 'en-GB', 'description' => 'Owner description',
        'feedbackEmail' => 'private-contact@example.test'}}] if path.end_with?('/betaAppLocalizations')
      return [{'id' => 'build-locale', 'attributes' => {'locale' => 'en-GB'}}] if path.end_with?('/betaBuildLocalizations')
      return [{'id' => 'public-alpha', 'attributes' => {'name' => 'Public Alpha', 'isInternalGroup' => false}}] if path.include?('/betaGroups?')
      return [build] if path == '/v1/betaGroups/public-alpha/builds?limit=200'
      return [{'id' => 'store-locale', 'attributes' => {'locale' => 'en-GB'}}] if path.end_with?('/appStoreVersionLocalizations')
      return [] if path.include?('/reviewSubmissions?') || path.end_with?('/items')
      raise "Unexpected list #{path}"
    end

    def patch(path, body)
      calls << [:patch, path, deep_copy(body)]
      if ['/v1/appStoreReviewDetails/version-review', '/v1/betaAppReviewDetails/beta-review'].include?(path)
        raise patch_error if patch_error
        assert_notes_only(body)
        target = path.include?('/betaAppReviewDetails/') ? beta_review : review
        target['attributes']['notes'] = body[:data][:attributes][:notes] if observe_write
      end
      {'data' => {}}
    end

    def post(path, body)
      calls << [:post, path, deep_copy(body)]
      {'data' => {'id' => 'new-review'}}
    end

    def assert_notes_only(body)
      raise 'Unexpected metadata mutation' unless body[:data][:attributes].keys == [:notes]
    end

    def projection(detail)
      {'id' => detail['id'], 'type' => detail['type'], 'attributes' => {'notes' => detail['attributes']['notes']}}
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end

  class Delivery < AppleRelease::Delivery
    attr_reader :receipts
    attr_accessor :approved
    def receipt(status, _build, extra = {})
      (@receipts ||= []) << [status, extra]
    end
    def system(*args)
      return false unless approved
      directory = args[args.index('--dir') + 1]
      File.write(File.join(directory, 'approval.json'), JSON.generate({
        'manifestHash' => Digest::SHA256.hexdigest(JSON.pretty_generate(@manifest) + "\n"),
        'actor' => 'crmitchelmore'}))
      true
    end
  end

  def helper(client, train: 'stable')
    AppleRelease::MacReviewNotes.new(client: client, train: train)
  end

  def notes_hash(client)
    Digest::SHA256.hexdigest(client.review['attributes']['notes'].to_s)
  end

  def repair(client)
    helper(client).repair(version_id: 'selected-version', expected_notes_hash: notes_hash(client))
  end

  def delivery(client, train:, surface: 'mac-store')
    notes = 'Frozen release notes'
    manifest = {'train' => train, 'source' => 'a' * 40, 'tag' => 'candidate', 'surfaces' => {
      surface => {'version' => '3.2.0', 'build' => '1000.0.1', 'notes' => notes,
        'notesHash' => Digest::SHA256.hexdigest(notes), 'storeNotes' => notes,
        'storeNotesHash' => Digest::SHA256.hexdigest(notes)}}}
    Delivery.new(client: client, manifest: manifest, surface: surface)
  end

  def test_audit_default_is_read_only_and_outputs_only_allowlisted_fields
    client = Client.new
    output = StringIO.new
    assert_equal 0, AppleRelease::MacReviewNotesCLI.run([], client_factory: -> { client }, output: output)
    record = JSON.parse(output.string).fetch(0)
    assert_equal %w[canonical_present notes_length notes_sha256 review_resource_id state version version_id], record.keys.sort
    assert_equal 'REJECTED', record['state']
    assert_equal notes_hash(client), record['notes_sha256']
    refute record['canonical_present']
    refute_match(/Owner notes|private-contact|private-login|private-password/, output.string)
    refute client.calls.any? { |call| %i[patch post].include?(call[0]) }
    assert client.calls.select { |call| call[1].include?('/appStoreReviewDetail') }.all? { |call| call[1].end_with?('fields[appStoreReviewDetails]=notes') }
  end

  def test_append_preserves_exact_owner_text_other_fields_and_is_idempotent
    client = Client.new
    original = client.deep_copy(client.review['attributes'])
    record = repair(client)
    after = client.review['attributes']
    assert after['notes'].start_with?(original['notes'] + "\n\n")
    assert_includes after['notes'], '_speaktransport._tcp'
    assert_includes after['notes'], 'A shipping iOS sender screen is not currently available'
    assert_equal original.reject { |key, _| key == 'notes' }, after.reject { |key, _| key == 'notes' }
    assert record[:canonical_present]
    helper(client).repair(version_id: 'selected-version', expected_notes_hash: record[:notes_sha256])
    assert_equal 1, client.calls.count { |call| call[0] == :patch }
  end

  def test_nil_notes_are_allowed_without_inventing_or_replacing_other_fields
    client = Client.new
    client.review['attributes']['notes'] = nil
    repair(client)
    assert client.review['attributes']['notes'].start_with?('The macOS app')
    assert_equal true, client.review['attributes']['demoAccountRequired']
  end

  def test_all_three_explicit_editable_states_allow_only_the_notes_patch
    %w[REJECTED PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED].each do |state|
      client = Client.new
      client.state = state
      assert_equal state, repair(client)[:state]
      assert_equal [[:patch, '/v1/appStoreReviewDetails/version-review']],
        client.calls.select { |call| %i[patch post].include?(call[0]) }.map { |call| call.first(2) }
    end
  end

  def test_mismatched_expected_hash_refuses_patch
    client = Client.new
    assert_raises(AppleRelease::MacReviewNotes::Error) do
      helper(client).repair(version_id: 'selected-version', expected_notes_hash: '0' * 64)
    end
    refute client.calls.any? { |call| call[0] == :patch }
  end

  def test_concurrent_notes_resource_and_state_changes_refuse_patch
    [->(client) { client.review['attributes']['notes'] = 'Concurrent owner edit' },
     ->(client) { client.review['id'] = 'replacement-resource' }].each do |change|
      client = Client.new
      client.before_second_read = change
      assert_raises(AppleRelease::MacReviewNotes::Error) { repair(client) }
      refute client.calls.any? { |call| call[0] == :patch }
    end
    client = Client.new
    client.before_second_version_read = ->(value) { value.state = 'IN_REVIEW' }
    assert_raises(AppleRelease::MacReviewNotes::Error) { repair(client) }
    refute client.calls.any? { |call| call[0] == :patch }
  end

  def test_state_change_after_guard_read_is_detected_without_claiming_atomic_patch
    client = Client.new
    client.before_second_read = ->(value) { value.state = 'IN_REVIEW' }
    assert_raises(AppleRelease::MacReviewNotes::Error) { repair(client) }
    assert_equal 1, client.calls.count { |call| call[0] == :patch }
    # No API compare-and-swap contract is claimed: this race is only detectable
    # after the notes-only PATCH, and must prevent any review submission.
    refute client.calls.any? { |call| call[0] == :post }
  end

  def test_noneditable_versions_wrong_bundle_foreign_version_and_ios_refuse_writes
    %w[IN_REVIEW WAITING_FOR_REVIEW READY_FOR_SALE READY_FOR_DISTRIBUTION PENDING_DEVELOPER_RELEASE].each do |state|
      client = Client.new
      client.state = state
      assert_raises(AppleRelease::MacReviewNotes::Error) { repair(client) }
      refute client.calls.any? { |call| call[0] == :patch }
    end
    client = Client.new
    client.bundle = 'different.bundle'
    assert_raises(AppleRelease::MacReviewNotes::Error) { repair(client) }
    assert_raises(AppleRelease::MacReviewNotes::Error) do
      helper(Client.new).repair(version_id: 'foreign-version', expected_notes_hash: 'a' * 64)
    end
    client = Client.new(surface: 'ios')
    assert_raises(AppleRelease::MacReviewNotes::Error) { repair(client) }
  end

  def test_missing_detail_is_audit_gap_and_repair_refuses_to_create_it
    client = Client.new
    client.missing_detail = true
    record = helper(client).audit.first
    assert_nil record[:review_resource_id]
    assert_nil record[:notes_sha256]
    assert_raises(AppleRelease::MacReviewNotes::Error) { repair(client) }
    refute client.calls.any? { |call| %i[post patch].include?(call[0]) }
  end

  def test_notes_capacity_failure_preserves_manual_text_without_truncation
    client = Client.new
    client.review['attributes']['notes'] = 'é' * 4000
    original = client.review['attributes']['notes'].dup
    assert_raises(AppleRelease::MacReviewNotes::Error) { repair(client) }
    assert_equal original, client.review['attributes']['notes']
    refute client.calls.any? { |call| call[0] == :patch }
  end

  def test_exact_readback_is_required_and_apple_errors_are_redacted_without_cause
    client = Client.new
    client.observe_write = false
    assert_raises(AppleRelease::MacReviewNotes::Error) { repair(client) }
    client = Client.new
    client.patch_error = IOSProfileBootstrap::ApiError.new('private-contact private-owner-notes', status: 403)
    error = assert_raises(AppleRelease::MacReviewNotes::Error) { repair(client) }
    assert_nil error.cause
    refute_match(/private/, error.message)
    errors = StringIO.new
    output = StringIO.new
    assert_equal 1, AppleRelease::MacReviewNotesCLI.run(
      ['--mode', 'repair', '--version-id', 'selected-version', '--expected-notes-sha256', notes_hash(client)],
      client_factory: -> { client }, output: output, errors: errors)
    assert_empty output.string
    refute_match(/private/, errors.string)
  end

  def test_invalid_selection_fails_before_credential_factory
    [['--mode', 'publish'], ['--mode', 'repair'], ['--version-id', "id\nnotes"],
     ['--mode', 'repair', '--version-id', '../foreign', '--expected-notes-sha256', 'a' * 64],
     ['--mode', 'repair', '--version-id', 'selected-version', '--expected-notes-sha256', 'not-a-hash']].each do |args|
      invoked = false
      assert_equal 1, AppleRelease::MacReviewNotesCLI.run(args, client_factory: -> { invoked = true }, errors: StringIO.new)
      refute invoked
    end
  end

  def test_explicit_onepassword_and_environment_sources_use_existing_client_without_fallback
    [{'APP_STORE_CONNECT_CREDENTIAL_SOURCE' => '1password'},
     {'APP_STORE_CONNECT_CREDENTIAL_SOURCE' => 'environment', 'APP_STORE_CONNECT_KEY_PATH' => '/owned/key.p8'}].each do |source|
      observed = nil
      AppleRelease::Client.stub(:new, ->(env:) { observed = env; :fake_client }) do
        assert_equal :fake_client, AppleRelease::MacReviewNotesCLI.client(env: source)
      end
      assert_same source, observed
    end
  end

  def test_missing_unknown_or_environment_without_key_path_refuse_before_client
    [{}, {'APP_STORE_CONNECT_CREDENTIAL_SOURCE' => 'other'},
     {'APP_STORE_CONNECT_CREDENTIAL_SOURCE' => 'environment'}].each do |source|
      AppleRelease::Client.stub(:new, ->(*) { flunk 'Credential client must not be constructed' }) do
        assert_raises(AppleRelease::MacReviewNotes::Error) { AppleRelease::MacReviewNotesCLI.client(env: source) }
      end
    end
  end

  def test_new_mac_beta_notes_are_verified_before_review_and_use_alpha_service
    client = Client.new(train: 'alpha')
    before = client.deep_copy(client.beta_review['attributes'])
    delivery(client, train: 'alpha').distribute(wait_seconds: 0)
    notes_patch = client.calls.index { |call| call[0] == :patch && call[1] == '/v1/betaAppReviewDetails/beta-review' }
    submission = client.calls.index { |call| call[0] == :post && call[1] == '/v1/betaAppReviewSubmissions' }
    assert notes_patch < submission
    assert_includes client.beta_review['attributes']['notes'], '_speakalpha._tcp'
    assert client.calls[(notes_patch + 1)...submission].any? { |call| call[0] == :get && call[1].include?('fields[betaAppReviewDetails]=notes') }
    assert_equal before.reject { |key, _| key == 'notes' }, client.beta_review['attributes'].reject { |key, _| key == 'notes' }
  end

  def test_unobserved_beta_notes_prevent_review_and_approved_beta_is_untouched
    client = Client.new(train: 'alpha')
    client.observe_write = false
    assert_raises(AppleRelease::MacReviewNotes::Error) { delivery(client, train: 'alpha').distribute(wait_seconds: 0) }
    refute client.calls.any? { |call| call[0] == :post && call[1] == '/v1/betaAppReviewSubmissions' }
    client = Client.new(train: 'alpha')
    client.beta_state = 'BETA_APPROVED'
    delivery(client, train: 'alpha').distribute(wait_seconds: 0)
    refute client.calls.any? { |call| call[1].include?('/betaAppReviewDetail') }
  end

  def test_ios_beta_flow_does_not_add_mac_listener_notes
    client = Client.new(train: 'alpha', surface: 'ios')
    before = client.beta_review['attributes']['notes'].dup
    delivery(client, train: 'alpha', surface: 'ios').distribute(wait_seconds: 0)
    assert_equal before, client.beta_review['attributes']['notes']
    refute client.calls.any? { |call| call[0] == :patch && call[1].include?('/betaAppReviewDetails/') }
  end

  def test_stable_owner_approval_still_precedes_notes_and_new_review
    client = Client.new
    instance = delivery(client, train: 'stable')
    assert_raises(RuntimeError) { instance.submit }
    refute client.calls.any? { |call| %i[patch post].include?(call[0]) }
    instance.approved = true
    instance.submit
    notes_patch = client.calls.index { |call| call[0] == :patch && call[1] == '/v1/appStoreReviewDetails/version-review' }
    submission = client.calls.index { |call| call[0] == :patch && call[1] == '/v1/reviewSubmissions/new-review' }
    assert notes_patch < submission
    assert client.calls[(notes_patch + 1)...submission].any? { |call| call[0] == :get && call[1].include?('fields[appStoreReviewDetails]=notes') }
  end

  def test_existing_stable_review_is_not_mutated
    client = Client.new
    client.state = 'IN_REVIEW'
    instance = delivery(client, train: 'stable')
    instance.approved = true
    instance.submit
    refute client.calls.any? { |call| %i[patch post].include?(call[0]) }
    refute client.calls.any? { |call| call[1].include?('/appStoreReviewDetail') }
  end

  def test_unobserved_stable_notes_prevent_build_attachment_and_review_submission
    client = Client.new
    client.observe_write = false
    instance = delivery(client, train: 'stable')
    instance.approved = true
    assert_raises(AppleRelease::MacReviewNotes::Error) { instance.submit }
    assert_equal ['/v1/appStoreReviewDetails/version-review'],
      client.calls.select { |call| %i[patch post].include?(call[0]) }.map { |call| call[1] }
  end
end

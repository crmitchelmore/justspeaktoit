require 'minitest/autorun'
require_relative '../testflight-testers'

class TestflightTestersTest < Minitest::Test
  PIPELINE = {'apple' => {'alpha' => {'ios' => 'alpha-app'}}}.freeze
  TRAINS = {'alpha' => {'iosBundleIdentifier' => 'com.justspeaktoit.ios.alpha'}}.freeze

  class FakeClient
    attr_accessor :testers, :build_state, :builds, :assigned, :invite_status, :create_conflict, :groups
    attr_reader :posts
    def initialize
      @testers = {} # email => {'id', 'groups', 'state'}
      @groups = [{'id' => 'public', 'attributes' => {'name' => 'Public Alpha', 'isInternalGroup' => false}},
                 {'id' => 'internal', 'attributes' => {'name' => 'Public Alpha', 'isInternalGroup' => true}}]
      @builds = [{'id' => 'b2', 'attributes' => {'version' => '12', 'processingState' => 'PROCESSING'}},
                 {'id' => 'b1', 'attributes' => {'version' => '11', 'processingState' => 'VALID', 'expired' => false,
                   'uploadedDate' => Time.now.utc.iso8601, 'expirationDate' => (Time.now + 60 * 86_400).utc.iso8601}}]
      @build_state = 'IN_BETA_TESTING'; @assigned = true; @posts = []
    end
    def get(path)
      route, query = path.split('?', 2)
      params = URI.decode_www_form(query.to_s).to_h
      case route
      when '/v1/apps/alpha-app' then {'data' => {'attributes' => {'bundleId' => 'com.justspeaktoit.ios.alpha'}}}
      when '/v1/builds' then {'data' => builds}
      when %r{\A/v1/builds/.+/buildBetaDetail\z} then {'data' => {'attributes' => {'externalBuildState' => build_state}}}
      when '/v1/betaTesters'
        found = testers.select { |email, t| email == params['filter[email]'] &&
          (!params['filter[betaGroups]'] || t['groups'].include?(params['filter[betaGroups]'])) }
        {'data' => found.map { |email, t| {'id' => t['id'], 'attributes' => {'email' => email, 'state' => t['state']}} }}
      else raise "Unexpected GET #{path}"
      end
    end
    def list(path)
      return groups if path == '/v1/apps/alpha-app/betaGroups?limit=200'
      return assigned ? [{'id' => 'b1'}] : [] if path == '/v1/betaGroups/public/builds?limit=200'
      raise "Unexpected list #{path}"
    end
    def post(path, body)
      @posts << [path, body]
      case path
      when '/v1/betaTesters'
        email = body[:data][:attributes][:email]
        raise IOSProfileBootstrap::ConflictError.new("conflict for #{email}", status: 409) if create_conflict
        testers[email] = {'id' => "t#{testers.length}", 'groups' => body[:data][:relationships][:betaGroups][:data].map { |g| g[:id] },
          'state' => 'NOT_INVITED'}
      when '/v1/betaGroups/public/relationships/betaTesters'
        id = body[:data].first[:id]
        testers.each_value { |t| t['groups'] << 'public' if t['id'] == id }
      when '/v1/betaTesterInvitations'
        raise IOSProfileBootstrap::ApiError.new('no build', status: invite_status) if invite_status
        id = body[:data][:relationships][:betaTester][:data][:id]
        testers.each_value { |t| t['state'] = 'INVITED' if t['id'] == id }
      else raise "Unexpected POST #{path}"
      end
      nil
    end
  end

  def access(client, lines = [])
    AppleRelease::TesterAccess.new(client: client, pipeline: PIPELINE, trains: TRAINS, log: ->(l) { lines << l })
  end

  def test_parse_emails_normalises_and_rejects_without_echoing
    assert_equal ['a@example.com', 'b@example.com'],
      AppleRelease::TesterAccess.parse_emails(' A@example.com, b@example.com ,a@example.com,')
    error = assert_raises(AppleRelease::TesterAccess::InputError) { AppleRelease::TesterAccess.parse_emails('secret-not-email') }
    refute_includes error.message, 'secret-not-email'
    assert_raises(AppleRelease::TesterAccess::InputError) { AppleRelease::TesterAccess.parse_emails('') }
  end

  def test_creates_new_tester_in_external_group_and_invites
    client = FakeClient.new
    lines = []
    counts = access(client, lines).ensure_testers(['new@example.com'])
    assert_equal 1, counts[:created]
    assert_equal 1, counts[:invited]
    assert_equal ['public'], client.testers['new@example.com']['groups']
    assert_equal 'INVITED', client.testers['new@example.com']['state']
    refute lines.join.include?('@'), 'logs must never contain addresses'
  end

  def test_existing_member_with_invitation_is_untouched
    client = FakeClient.new
    client.testers['me@example.com'] = {'id' => 't0', 'groups' => ['public'], 'state' => 'INSTALLED'}
    counts = access(client).ensure_testers(['me@example.com'])
    assert_equal 1, counts[:already]
    assert_empty client.posts
  end

  def test_account_tester_is_linked_and_invited_for_this_app
    client = FakeClient.new
    client.testers['me@example.com'] = {'id' => 't0', 'groups' => ['other'], 'state' => 'ACCEPTED'}
    counts = access(client).ensure_testers(['me@example.com'])
    assert_equal 1, counts[:linked]
    assert_equal 1, counts[:invited]
    assert_equal ['/v1/betaGroups/public/relationships/betaTesters', '/v1/betaTesterInvitations'], client.posts.map(&:first)
  end

  def test_create_conflict_falls_back_to_linking
    client = FakeClient.new
    client.create_conflict = true
    def client.get(path)
      # The tester appears only after Apple reports the conflict.
      testers['race@example.com'] ||= {'id' => 'tr', 'groups' => [], 'state' => 'NOT_INVITED'} if posts.any?
      super
    end
    counts = access(client).ensure_testers(['race@example.com'])
    assert_equal 1, counts[:linked]
    assert_includes client.testers['race@example.com']['groups'], 'public'
  end

  def test_invitation_rejected_until_build_is_testable_stays_pending
    client = FakeClient.new
    client.invite_status = 422
    counts = access(client).ensure_testers(['new@example.com'])
    assert_equal 1, counts[:invite_pending]
    client.invite_status = 403
    assert_raises(IOSProfileBootstrap::ApiError) { access(client).ensure_testers(['other@example.com']) }
  end

  def test_requires_single_external_group
    client = FakeClient.new
    client.groups = client.groups.reject { |g| g['id'] == 'public' }
    assert_raises(RuntimeError) { access(client).ensure_testers(['a@example.com']) }
  end

  def test_verify_reports_latest_valid_build_and_membership
    client = FakeClient.new
    client.testers['me@example.com'] = {'id' => 't0', 'groups' => ['public'], 'state' => 'INVITED'}
    lines = []
    result = access(client, lines).verify(['me@example.com'])
    assert_empty result[:problems]
    assert_equal '11', result[:build][:number]
    assert lines.any? { |l| l.include?('build 11: IN_BETA_TESTING') }
    assert lines.any? { |l| l.end_with?('1 invited (INVITED=1)') }
    refute lines.join.include?('@')
  end

  def test_verify_accepts_waiting_for_review_but_flags_other_states
    client = FakeClient.new
    client.testers['me@example.com'] = {'id' => 't0', 'groups' => ['public'], 'state' => 'INVITED'}
    client.build_state = 'WAITING_FOR_BETA_REVIEW'; client.assigned = false
    assert_empty access(client).verify(['me@example.com'])[:problems]
    client.build_state = 'READY_FOR_BETA_SUBMISSION'
    assert_equal ['Build 11 is READY_FOR_BETA_SUBMISSION'], access(client).verify(['me@example.com'])[:problems]
    client.build_state = 'IN_BETA_TESTING'
    assert_equal ['Build 11 is not assigned to Public Alpha'], access(client).verify(['me@example.com'])[:problems]
  end

  def test_verify_flags_missing_and_uninvited_testers_by_count
    client = FakeClient.new
    client.testers['me@example.com'] = {'id' => 't0', 'groups' => ['public'], 'state' => 'NOT_INVITED'}
    problems = access(client).verify(['me@example.com', 'gone@example.com'])[:problems]
    assert_equal ['1 configured testers are not in Public Alpha', '1 testers have no invitation yet'], problems
  end

  def test_recent_requires_fresh_unexpired_build
    tester = access(FakeClient.new)
    now = Time.utc(2026, 11, 8)
    assert tester.recent?({uploaded: '2026-11-01T00:00:00Z', expires: '2027-01-01T00:00:00Z'}, now: now)
    refute tester.recent?({uploaded: '2026-09-01T00:00:00Z', expires: '2027-01-01T00:00:00Z'}, now: now)
    refute tester.recent?({uploaded: '2026-11-01T00:00:00Z', expires: '2026-11-10T00:00:00Z'}, now: now)
    refute tester.recent?(nil, now: now)
  end

  def test_redact_removes_plain_and_encoded_addresses
    text = 'GET /v1/betaTesters?filter%5Bemail%5D=me%40example.com failed: {"email":"Me@Example.com"}'
    redacted = AppleRelease::TesterAccess.redact(text, ['me@example.com'])
    refute_match(/example/i, redacted)
    assert_includes redacted, 'failed'
  end

  def test_identity_mismatch_stops_before_writes
    client = FakeClient.new
    def client.get(path)
      return {'data' => {'attributes' => {'bundleId' => 'com.other'}}} if path == '/v1/apps/alpha-app'
      super
    end
    assert_raises(RuntimeError) { access(client) }
  end
end

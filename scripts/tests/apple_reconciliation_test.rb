require 'minitest/autorun'
require 'open3'
require_relative '../apple-reconciliation'
require_relative '../release-apple'

class AppleReconciliationTest < Minitest::Test
  def empty_state
    {current_alpha: nil, pending_alphas: []}
  end

  def manifest(ordinal, train: 'alpha', selected: nil, age: 0)
    {'train'=>train, 'tag'=>"#{train == 'alpha' ? 'alpha-build' : 'stable-candidate'}-#{ordinal}",
     'ordinal'=>ordinal, 'selectedAlpha'=>selected, 'createdAt'=>(Time.now - age * 86_400).utc.iso8601}
  end

  def test_reconciles_latest_alpha_and_frozen_stable_selection_not_every_old_upload
    manifests=[manifest(1), manifest(2), manifest(42), manifest(1, train: 'stable', selected: 'alpha-build-2')]
    assert_equal %w[alpha-build-42 alpha-build-2 stable-candidate-1], AppleRelease.reconciliation_manifests(manifests, state: empty_state).map { |m| m['tag'] }
  end

  def test_ordinal_order_not_lexical_and_expired_alpha_is_excluded
    assert_equal ['alpha-build-10'], AppleRelease.reconciliation_manifests([manifest(9),manifest(10)], state: empty_state).map { |m| m['tag'] }
    assert_empty AppleRelease.reconciliation_manifests([manifest(11,age:91)], state: empty_state)
  end

  def test_explicit_historical_tag_is_available_without_reactivating_every_old_build
    manifests=[manifest(1),manifest(42)]
    assert_equal [manifests.first], AppleRelease.reconciliation_manifests(manifests,tag:'alpha-build-1')
    assert_raises(RuntimeError) { AppleRelease.reconciliation_manifests(manifests,tag:'main') }
  end

  def test_all_stable_candidates_remain_eligible_for_publication_observation
    manifests=[manifest(1,train:'stable'),manifest(2,train:'stable')]
    assert_equal 2, AppleRelease.reconciliation_manifests(manifests, state: empty_state).size
  end

  def request_sequence(method, statuses)
    calls=[]
    transport=Object.new
    transport.define_singleton_method(:call) do |**args|
      calls << args
      [statuses.shift, '{"data":[]}']
    end
    client=AppleRelease::Client.allocate
    client.instance_variable_set(:@key_id,'TEST')
    client.instance_variable_set(:@issuer,'test')
    client.instance_variable_set(:@key,OpenSSL::PKey::EC.generate('prime256v1'))
    client.define_singleton_method(:retry_pause) { |_attempt| }
    IOSProfileBootstrap::HttpTransport.stub(:new,->(**_args) { transport }) do
      begin
        client.request(method:method,path:'/v1/builds')
      rescue IOSProfileBootstrap::ApiError
        # The assertion below verifies both bounded retry and final failure.
        yield calls if block_given?
        return [:failed,calls.size]
      end
    end
    [:success,calls.size]
  end

  def test_transient_get_failure_retries_and_recovers
    assert_equal [:success,3], request_sequence(Net::HTTP::Get,[500,503,200])
  end

  def test_persistent_get_failure_is_bounded
    assert_equal [:failed,3], request_sequence(Net::HTTP::Get,[500,500,500,200])
  end

  def test_writes_and_auth_failures_are_not_replayed
    assert_equal [:failed,1], request_sequence(Net::HTTP::Post,[500,200])
    assert_equal [:failed,1], request_sequence(Net::HTTP::Get,[403,200])
  end

  def alpha(ordinal, age: 0)
    value = manifest(ordinal, age: age)
    value.merge('source' => 'a' * 40, 'build' => "2026102800#{ordinal}", 'surfaces' =>
      %w[ios mac-store].to_h { |surface| [surface, {'build' => "1000.0.#{ordinal}",
        'notes' => "Frozen #{surface}", 'notesHash' => Digest::SHA256.hexdigest("Frozen #{surface}")}] })
  end

  def pointer(value)
    value.slice('tag', 'build', 'source')
  end

  def receipt(value, status: 'processing', surface: 'ios')
    item = value.fetch('surfaces').fetch(surface)
    {'source' => value.fetch('source'), 'build' => item.fetch('build'), 'notesHash' => item.fetch('notesHash'),
      'status' => status, 'appleBuildID' => nil, 'expirationDate' => nil}
  end

  def snapshot_reader(rows)
    assets = {}
    releases = rows.map do |tag, named|
      {'tag_name' => tag, 'assets' => named.map do |name, value|
        id = assets.size + 1
        assets[id] = value
        {'id' => id, 'name' => name, 'size' => 100}
      end}
    end
    reader = Object.new
    reader.define_singleton_method(:releases) { releases }
    reader.define_singleton_method(:asset) do |asset|
      value = assets.fetch(asset.fetch('id'))
      raise value if value.is_a?(Exception)
      value
    end
    reader
  end

  def selected(manifests, reader, **options)
    state = AppleRelease.reconciliation_state(manifests, reader: reader, **options.slice(:now))
    AppleRelease.reconciliation_manifests(manifests, state: state, **options).map { |value| value.fetch('tag') }
  end

  def test_new_allocation_retains_bound_current_pointer_and_does_not_infer_apple_delivery
    old = alpha(42); newest = alpha(43)
    reader = snapshot_reader('alpha-latest' => {'alpha-pointer.json' => pointer(old)})
    assert_equal %w[alpha-build-43 alpha-build-42], selected([old, newest], reader)
    assert_equal ['alpha-build-43'], selected([old, newest], snapshot_reader({}))
    assert_raises(AppleRelease::ReconciliationInputError) { AppleRelease.reconciliation_manifests([old, newest]) }
  end

  def test_each_bound_pending_surface_is_retained_independently_of_newest_allocation
    old = alpha(42); newest = alpha(43)
    AppleRelease::PENDING_APPLE_RECEIPTS.each do |status|
      %w[ios mac-store].each do |surface|
        reader = snapshot_reader(old.fetch('tag') => {"#{surface}-receipt.json" => receipt(old, status: status, surface: surface)})
        assert_equal %w[alpha-build-43 alpha-build-42], selected([old, newest], reader), "#{surface} #{status}"
      end
    end
    reader = snapshot_reader(old.fetch('tag') => {'ios-receipt.json' => receipt(old, status: 'verified'),
      'mac-store-receipt.json' => receipt(old, surface: 'mac-store')})
    assert_equal %w[alpha-build-43 alpha-build-42], selected([old, newest], reader)
  end

  def test_terminal_historical_receipts_are_excluded_but_current_pointer_still_retained
    old = alpha(42); newest = alpha(43)
    %w[verified invalid beta_rejected].each do |status|
      rows = {old.fetch('tag') => {'ios-receipt.json' => receipt(old, status: status)}}
      assert_equal ['alpha-build-43'], selected([old, newest], snapshot_reader(rows))
      rows['alpha-latest'] = {'alpha-pointer.json' => pointer(old)}
      assert_equal %w[alpha-build-43 alpha-build-42], selected([old, newest], snapshot_reader(rows))
    end
  end

  def test_pointer_missing_malformed_unknown_and_mismatched_identities_fail_closed
    value = alpha(42)
    [{}, {'alpha-pointer.json' => nil}, {'alpha-pointer.json' => pointer(value).merge('tag' => 'alpha-build-999')},
      {'alpha-pointer.json' => pointer(value).merge('source' => 'b' * 40)},
      {'alpha-pointer.json' => pointer(value).merge('build' => 'different')}].each do |assets|
      assert_raises(AppleRelease::ReconciliationInputError) do
        selected([value], snapshot_reader('alpha-latest' => assets))
      end
    end
  end

  def test_receipt_identity_unknown_state_and_malformed_expiry_fail_without_echoing_canaries
    value = alpha(42)
    [{'source' => 'PRIVATE_CANARY'}, {'build' => 'PRIVATE_CANARY'}, {'notesHash' => 'PRIVATE_CANARY'},
      {'status' => 'PRIVATE_CANARY'}, {'expirationDate' => 'PRIVATE_CANARY'}].each do |change|
      error = assert_raises(AppleRelease::ReconciliationInputError) do
        selected([value], snapshot_reader(value.fetch('tag') => {'ios-receipt.json' => receipt(value).merge(change)}))
      end
      refute_includes error.message, 'PRIVATE_CANARY'
    end
    value.fetch('surfaces').fetch('ios')['notes'] = 'PRIVATE_CANARY'
    error = assert_raises(AppleRelease::ReconciliationInputError) do
      selected([value], snapshot_reader('alpha-latest' => {'alpha-pointer.json' => pointer(value)}))
    end
    refute_includes error.message, 'PRIVATE_CANARY'
  end

  def test_proven_absence_is_distinct_from_failed_asset_or_metadata_acquisition
    old = alpha(42); newest = alpha(43)
    assert_equal ['alpha-build-43'], selected([old, newest], snapshot_reader(old.fetch('tag') => {}))
    error = assert_raises(AppleRelease::ReconciliationInputError) do
      selected([old, newest], snapshot_reader(old.fetch('tag') => {'ios-receipt.json' => RuntimeError.new('SECRET_ERROR')}))
    end
    refute_includes error.message, 'SECRET_ERROR'
    reader = snapshot_reader({})
    reader.define_singleton_method(:releases) { raise 'SECRET_TOKEN' }
    error = assert_raises(AppleRelease::ReconciliationInputError) { selected([old, newest], reader) }
    refute_includes error.message, 'SECRET_TOKEN'
  end

  def test_expired_receipts_are_not_read_and_current_stable_age_exclusions_are_explicit
    now = Time.now
    old = alpha(42, age: 91); newest = alpha(43)
    stable = manifest(1, train: 'stable', selected: old.fetch('tag'))
    rows = {'alpha-latest' => {'alpha-pointer.json' => pointer(old)},
      old.fetch('tag') => {'ios-receipt.json' => RuntimeError.new('IRRELEVANT_OLD_RECEIPT')}}
    observations = []
    assert_equal %w[alpha-build-43 stable-candidate-1], selected([old, newest, stable], snapshot_reader(rows), now: now,
      observe: ->(category, count) { observations << [category, count] })
    assert_equal [[:expired_alpha, 1], [:expired_current_alpha, 1], [:expired_stable_selected_alpha, 1]], observations
    assert_equal [old], AppleRelease.reconciliation_manifests([old], tag: old.fetch('tag'))
    invalid = pointer(old).merge('build' => 'mismatch')
    assert_raises(AppleRelease::ReconciliationInputError) do
      selected([old, newest], snapshot_reader('alpha-latest' => {'alpha-pointer.json' => invalid}), now: now)
    end
    boundary = alpha(41); boundary['createdAt'] = (now - 90 * 86_400).utc.iso8601(6)
    assert_equal ['alpha-build-41'], selected([boundary], snapshot_reader({}), now: Time.iso8601(now.utc.iso8601(6)))
  end

  def test_duplicate_releases_and_named_assets_refuse_incomplete_or_ambiguous_snapshot
    value = alpha(42)
    reader = snapshot_reader('alpha-latest' => {'alpha-pointer.json' => pointer(value)})
    rows = reader.releases
    reader.define_singleton_method(:releases) { rows + rows }
    assert_raises(AppleRelease::ReconciliationInputError) { selected([value], reader) }
    reader = snapshot_reader('alpha-latest' => {'alpha-pointer.json' => pointer(value)})
    reader.releases.first.fetch('assets') << reader.releases.first.fetch('assets').first.dup
    assert_raises(AppleRelease::ReconciliationInputError) { selected([value], reader) }
  end

  def test_real_reader_consumes_all_projected_pages_and_only_fixed_bound_asset_routes
    value = alpha(42); newest = alpha(43)
    rows = [{'tag_name' => newest.fetch('tag'), 'assets' => []},
      {'tag_name' => 'alpha-latest', 'assets' => [{'name' => 'alpha-pointer.json', 'id' => 7, 'size' => 100}]},
      {'tag_name' => value.fetch('tag'), 'assets' => [{'name' => 'ios-receipt.json', 'id' => 8, 'size' => 200}]}]
    calls = []
    reader = AppleRelease::ReconciliationReader.new(command: ->(arguments, limit) do
      calls << [arguments, limit]
      case arguments[2]
      when '--paginate' then rows.map { |row| JSON.generate(row) }.join("\n") + "\n"
      when %r{/assets/7\z} then JSON.generate(pointer(value))
      when %r{/assets/8\z} then JSON.generate(receipt(value))
      else flunk 'Unexpected acquisition route'
      end
    end)
    assert_equal %w[alpha-build-43 alpha-build-42], selected([value, newest], reader)
    assert_includes calls.first.first, '--paginate'
    assert_equal [4 * 1024 * 1024, 65_536, 65_536], calls.map(&:last)
    assert_equal %w[repos/crmitchelmore/justspeaktoit/releases/assets/7 repos/crmitchelmore/justspeaktoit/releases/assets/8],
      calls.drop(1).map { |call| call.first[2] }
  end

  def test_real_reader_caps_json_and_sanitizes_failed_commands_and_non_object_json
    value = alpha(42)
    [->(_args, _limit) { 'x' * (4 * 1024 * 1024 + 1) },
      ->(_args, _limit) { raise 'SECRET_URL_TOKEN' },
      ->(_args, _limit) { '{broken SECRET_URL_TOKEN' }].each do |command|
      error = assert_raises(AppleRelease::ReconciliationInputError) do
        selected([value], AppleRelease::ReconciliationReader.new(command: command))
      end
      refute_includes error.message, 'SECRET_URL_TOKEN'
    end
    reader = AppleRelease::ReconciliationReader.new(command: ->(_args, _limit) { '[]' })
    assert_raises(AppleRelease::ReconciliationInputError) { reader.asset({'id' => 1, 'size' => 65_537}) }
    assert_raises(AppleRelease::ReconciliationInputError) { reader.asset({'id' => true, 'size' => 10}) }
    assert_raises(AppleRelease::ReconciliationInputError) do
      selected([value], snapshot_reader(value.fetch('tag') => {'ios-receipt.json' => []}))
    end
  end


  def test_owned_command_reader_bounds_output_and_contains_private_stderr
    require 'rbconfig'
    reader = AppleRelease::ReconciliationReader.new
    assert_equal '{"safe":true}', reader.send(:capture, [RbConfig.ruby, '-e', 'print %q({"safe":true})'], 64)
    assert_raises(AppleRelease::ReconciliationInputError) do
      reader.send(:capture, [RbConfig.ruby, '-e', 'STDOUT.write("x" * 4096)'], 32)
    end
    assert_raises(AppleRelease::ReconciliationInputError) do
      reader.send(:capture, [RbConfig.ruby, '-e', 'STDERR.write("PRIVATE_CANARY"); exit 1'], 64)
    end
  end

  def run_manifest_loading(ledger, annotations, requested:)
    reads = []
    client_calls = 0
    snapshot_calls = 0
    client_boundary = RuntimeError.new('Test stopped before constructing Apple client')
    previous = ENV['RECONCILE_TAG']
    ENV['RECONCILE_TAG'] = requested
    command = ->(*arguments) do
      if arguments == ['git', 'for-each-ref', '--format=%(refname:short)',
          'refs/tags/alpha-build-*', 'refs/tags/stable-candidate-*']
        [ledger.join("\n") + "\n", Struct.new(:success?).new(true)]
      else
        tag = arguments.fetch(3).delete_prefix('refs/tags/')
        assert_equal ['git', 'for-each-ref', '--format=%(contents)', "refs/tags/#{tag}"], arguments
        reads << tag
        data, success = annotations.fetch(tag)
        [data, Struct.new(:success?).new(success)]
      end
    end
    error = nil
    capture_io do
      Open3.stub(:capture2, command) do
        AppleRelease.stub(:reconciliation_state, ->(*_args) { snapshot_calls += 1; raise 'Unexpected snapshot acquisition' }) do
          AppleRelease::Client.stub(:new, -> { client_calls += 1; raise client_boundary }) do
            begin
              load File.expand_path('../reconcile-apple-releases.rb', __dir__)
            rescue StandardError, SystemExit => caught
              error = caught
            end
          end
        end
      end
    end
    {error: error, reads: reads, client_calls: client_calls, snapshot_calls: snapshot_calls,
      client_boundary: client_boundary}
  ensure
    previous.nil? ? ENV.delete('RECONCILE_TAG') : ENV['RECONCILE_TAG'] = previous
  end

  def test_explicit_runner_reads_only_requested_annotation_before_client_boundary
    [alpha(42, age: 91), manifest(1, train: 'stable')].each do |value|
      tag = value.fetch('tag')
      result = run_manifest_loading([tag, 'alpha-build-999', 'stable-candidate-999'],
        {tag => [JSON.generate(value), true], 'alpha-build-999' => ['{broken', true],
          'stable-candidate-999' => ['{broken', true]}, requested: " #{tag} ")
      assert_same result[:client_boundary], result[:error]
      assert_equal [tag], result[:reads]
      assert_equal 1, result[:client_calls]
      assert_equal 0, result[:snapshot_calls]
    end
  end

  def test_explicit_runner_rejects_invalid_missing_malformed_mismatched_or_unreadable_target
    value = alpha(42)
    tag = value.fetch('tag')
    cases = [
      {requested: '../PRIVATE_CANARY', annotation: [JSON.generate(value), true], error: RuntimeError, reads: []},
      {requested: 'alpha-build-41', annotation: [JSON.generate(value), true], error: RuntimeError, reads: []},
      {requested: tag, annotation: ['{broken', true], error: JSON::ParserError, reads: [tag]},
      {requested: tag, annotation: [JSON.generate(alpha(43)), true], error: RuntimeError, reads: [tag]},
      {requested: tag, annotation: [JSON.generate(value), false], error: SystemExit, reads: [tag]}
    ]
    cases.each do |entry|
      result = run_manifest_loading([tag], {tag => entry[:annotation]}, requested: entry[:requested])
      assert_instance_of entry[:error], result[:error]
      refute_same result[:client_boundary], result[:error]
      refute_includes result[:error].message, 'PRIVATE_CANARY'
      assert_equal entry[:reads], result[:reads]
      assert_equal 0, result[:client_calls]
      assert_equal 0, result[:snapshot_calls]
    end
  end

  def test_scheduled_runner_still_rejects_any_malformed_annotation_before_snapshot_or_client
    value = alpha(42)
    %w[alpha-build-41 stable-candidate-1].each do |malformed|
      result = run_manifest_loading([value.fetch('tag'), malformed],
        {value.fetch('tag') => [JSON.generate(value), true], malformed => ['{broken', true]}, requested: ' ')
      assert_instance_of JSON::ParserError, result[:error]
      assert_equal [value.fetch('tag'), malformed], result[:reads]
      assert_equal 0, result[:snapshot_calls]
      assert_equal 0, result[:client_calls]
    end
  end

end

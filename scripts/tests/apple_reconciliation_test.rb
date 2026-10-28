require 'minitest/autorun'
require_relative '../apple-reconciliation'
require_relative '../release-apple'

class AppleReconciliationTest < Minitest::Test
  def manifest(ordinal, train: 'alpha', selected: nil, age: 0)
    {'train'=>train, 'tag'=>"#{train == 'alpha' ? 'alpha-build' : 'stable-candidate'}-#{ordinal}",
     'ordinal'=>ordinal, 'selectedAlpha'=>selected, 'createdAt'=>(Time.now - age * 86_400).utc.iso8601}
  end

  def test_reconciles_latest_alpha_and_frozen_stable_selection_not_every_old_upload
    manifests=[manifest(1), manifest(2), manifest(42), manifest(1, train: 'stable', selected: 'alpha-build-2')]
    assert_equal %w[alpha-build-42 alpha-build-2 stable-candidate-1], AppleRelease.reconciliation_manifests(manifests).map { |m| m['tag'] }
  end

  def test_ordinal_order_not_lexical_and_expired_alpha_is_excluded
    assert_equal ['alpha-build-10'], AppleRelease.reconciliation_manifests([manifest(9),manifest(10)]).map { |m| m['tag'] }
    assert_empty AppleRelease.reconciliation_manifests([manifest(11,age:91)])
  end

  def test_explicit_historical_tag_is_available_without_reactivating_every_old_build
    manifests=[manifest(1),manifest(42)]
    assert_equal [manifests.first], AppleRelease.reconciliation_manifests(manifests,tag:'alpha-build-1')
    assert_raises(RuntimeError) { AppleRelease.reconciliation_manifests(manifests,tag:'main') }
  end

  def test_all_stable_candidates_remain_eligible_for_publication_observation
    manifests=[manifest(1,train:'stable'),manifest(2,train:'stable')]
    assert_equal 2, AppleRelease.reconciliation_manifests(manifests).size
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
end

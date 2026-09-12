require 'minitest/autorun'
require_relative '../release-apple'

class ReleaseAppleTest < Minitest::Test
  class FakeClient
    attr_accessor :processing, :beta_state, :review_busy, :assigned, :bundle_id
    attr_reader :posts
    def initialize
      @bundle_id='com.justspeaktoit.ios.alpha'; @processing='VALID'; @beta_state='READY_FOR_BETA_SUBMISSION'; @review_busy=false; @assigned=false; @posts=[]
    end
    def build
      {'id'=>'apple-build','attributes'=>{'processingState'=>processing,'expired'=>false,'expirationDate'=>'2026-12-01T00:00:00Z'}}
    end
    def get(path)
      return {'data'=>{'attributes'=>{'bundleId'=>bundle_id}}} if path.start_with?('/v1/apps/')
      {'data'=>{'attributes'=>{'externalBuildState'=>assigned ? 'IN_BETA_TESTING' : beta_state}}}
    end
    def list(path)
      if path.start_with?('/v1/builds?')
        return review_busy ? [build] : [] if path.include?('betaAppReviewSubmission')
        return [build]
      end
      return [] if path.end_with?('/betaBuildLocalizations')
      return [{'id'=>'public-alpha','attributes'=>{'name'=>'Public Alpha','isInternalGroup'=>false,'publicLink'=>'https://testflight.apple.com/join/example'}}] if path.include?('/apps/')
      assigned ? [build] : []
    end
    def post(path, body)
      @posts << path
      @assigned=true if path.end_with?('/relationships/builds')
      {'data'=>{}}
    end
    def patch(path, body); {'data'=>{}}; end
  end
  class Delivery < AppleRelease::Delivery
    attr_reader :receipts
    def receipt(status, build, extra={})
      (@receipts ||= []) << [status,extra]
    end
  end
  def delivery(client, train: 'alpha')
    notes='Frozen notes'
    manifest={'train'=>train,'source'=>'a'*40,'tag'=>'alpha-build-1','surfaces'=>{'ios'=>{'version'=>'3.2.0','build'=>'1000.0.1','notes'=>notes,'notesHash'=>Digest::SHA256.hexdigest(notes),'storeNotes'=>notes,'storeNotesHash'=>Digest::SHA256.hexdigest(notes)}}}
    Delivery.new(client:client,manifest:manifest,surface:'ios')
  end
  def test_stable_candidate_never_assigns_testers
    client=FakeClient.new; client.bundle_id=client.bundle_id.delete_suffix('.alpha')
    d=delivery(client, train: 'stable'); d.distribute(wait_seconds:0)
    assert_equal 'verified', d.receipts.last.first
    assert_equal 'app_store_candidate', d.receipts.last.last[:distribution]
    assert_empty d.receipts.last.last[:groups]
    assert_empty client.posts
    refute client.assigned
    assert_raises(RuntimeError) { d.assign(client.build) }
  end
  def test_alpha_cannot_enter_app_store_review
    client=FakeClient.new
    error=assert_raises(RuntimeError) { delivery(client).submit }
    assert_match 'Alpha must never enter App Store review', error.message
    assert_empty client.posts
  end
  def test_processing_is_pending_not_delivery
    client=FakeClient.new;client.processing='PROCESSING';d=delivery(client);d.distribute(wait_seconds:0)
    assert_equal 'processing',d.receipts.last.first
    assert_empty client.posts
  end
  def test_busy_review_slot_preserves_pending_build
    client=FakeClient.new;client.review_busy=true;d=delivery(client);d.distribute(wait_seconds:0)
    assert_equal 'waiting_for_beta_review_slot',d.receipts.last.first
    refute client.posts.any?{|path|path.end_with?('/betaAppReviewSubmissions')}
    refute client.assigned
  end
  def test_approved_build_requires_observed_group_assignment
    client=FakeClient.new;client.beta_state='BETA_APPROVED';d=delivery(client);d.distribute(wait_seconds:0)
    assert client.assigned
    assert_equal 'verified',d.receipts.last.first
    assert_equal ['https://testflight.apple.com/join/example'],d.receipts.last.last[:publicLinks]
  end
  def test_rejected_beta_is_actionable_not_indefinitely_pending
    client=FakeClient.new;client.beta_state='BETA_REJECTED';d=delivery(client)
    assert_raises(RuntimeError){d.distribute(wait_seconds:0)}
    assert_equal 'beta_rejected',d.receipts.last.first
    refute client.assigned
  end
  def test_invalid_upload_requires_a_new_build_number
    client=FakeClient.new;client.processing='INVALID';d=delivery(client)
    assert_raises(RuntimeError){d.distribute(wait_seconds:0)}
    assert_equal 'invalid',d.receipts.last.first
  end
end

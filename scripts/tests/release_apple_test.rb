require 'minitest/autorun'
require_relative '../release-apple'

class ReleaseAppleTest < Minitest::Test
  class FakeClient
    attr_accessor :processing, :beta_state, :review_busy, :assigned, :bundle_id
    attr_reader :posts
    attr_accessor :beta_locales, :review_contact, :stable_contact, :store_contact
    def initialize
      @bundle_id='com.justspeaktoit.ios.alpha'; @processing='VALID'; @beta_state='READY_FOR_BETA_SUBMISSION'; @review_busy=false; @assigned=false; @posts=[]; @beta_locales=[]; @review_contact={'contactFirstName'=>'Owner','contactLastName'=>'Tester','contactPhone'=>'+441234567890','contactEmail'=>'owner@example.com'}; @stable_contact=@review_contact.dup; @store_contact=@review_contact.dup
    end
    def build
      {'id'=>'apple-build','attributes'=>{'processingState'=>processing,'expired'=>false,'expirationDate'=>'2026-12-01T00:00:00Z'}}
    end
    def get(path)
      return {'data'=>{'id'=>'store-review','attributes'=>store_contact}} if path.end_with?('/appStoreReviewDetail')
      return {'data'=>{'id'=>'review','attributes'=>path.include?('6810300888') ? review_contact : stable_contact}} if path.end_with?('/betaAppReviewDetail')
      return {'data'=>{'attributes'=>{'bundleId'=>bundle_id}}} if path.start_with?('/v1/apps/')
      {'data'=>{'attributes'=>{'externalBuildState'=>assigned ? 'IN_BETA_TESTING' : beta_state}}}
    end
    def list(path)
      return [{'id'=>'stable-version'}] if path.end_with?('/appStoreVersions?limit=200')
      return beta_locales if path.end_with?('/betaAppLocalizations')
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
      @beta_locales << {'id'=>'beta-locale', 'attributes'=>body[:data][:attributes].transform_keys(&:to_s)} if path == '/v1/betaAppLocalizations'
      @assigned=true if path.end_with?('/relationships/builds')
      {'data'=>{}}
    end
    def patch(path, body)
      review_contact.merge!(body[:data][:attributes].transform_keys(&:to_s)) if path.start_with?('/v1/betaAppReviewDetails/')
      beta_locales.find { |l| path.end_with?(l['id']) }['attributes'].merge!(body[:data][:attributes].transform_keys(&:to_s)) if path.start_with?('/v1/betaAppLocalizations/')
      {'data'=>{}}
    end
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
  def test_beta_description_is_created_once_and_existing_copy_is_preserved
    client=FakeClient.new; d=delivery(client)
    d.ensure_beta_description
    assert_equal 1,client.beta_locales.size
    client.beta_locales.first['attributes']['description']='Owner copy'
    d.ensure_beta_description
    assert_equal 'Owner copy',client.beta_locales.first['attributes']['description']
    assert_equal 1,client.posts.count('/v1/betaAppLocalizations')
  end
  def test_missing_english_description_is_repaired_before_beta_review
    client=FakeClient.new
    client.beta_locales=[{'id'=>'existing','attributes'=>{'locale'=>'en-US','description'=>''}}]
    delivery(client).distribute(wait_seconds:0)
    refute_empty client.beta_locales.first['attributes']['description']
    assert_includes client.posts,'/v1/betaAppReviewSubmissions'
  end
  def test_concurrent_localization_creation_is_verified_without_claiming_review_wait
    client=FakeClient.new
    def client.post(path,body)
      super
      raise IOSProfileBootstrap::ConflictError.new('created concurrently',status:409) if path == '/v1/betaAppLocalizations'
    end
    d=delivery(client); d.distribute(wait_seconds:0)
    assert_equal 'beta_review_pending',d.receipts.last.first
    assert_includes client.posts,'/v1/betaAppReviewSubmissions'
  end
  def test_existing_translated_description_is_preserved
    client=FakeClient.new
    client.beta_locales=[{'id'=>'french','attributes'=>{'locale'=>'fr-FR','description'=>'Version de test'}}]
    delivery(client).ensure_beta_description
    assert_empty client.posts
    assert_equal 'Version de test',client.beta_locales.first['attributes']['description']
  end
  def test_repairs_missing_alpha_contacts_and_feedback_from_existing_owner_data
    client=FakeClient.new; client.review_contact['contactPhone']=''
    client.beta_locales=[{'id'=>'beta','attributes'=>{'locale'=>'en-GB','description'=>'Owner copy'}}]
    delivery(client).ensure_beta_review_information
    assert_equal client.stable_contact['contactPhone'],client.review_contact['contactPhone']
    assert_equal 'Owner copy',client.beta_locales.first['attributes']['description']
    assert_equal 'owner@example.com',client.beta_locales.first['attributes']['feedbackEmail']
  end
  def test_repairs_contacts_from_store_review_when_stable_beta_contact_is_missing
    client=FakeClient.new
    client.review_contact['contactPhone']=''
    client.stable_contact['contactPhone']=''
    client.store_contact['contactPhone']='+441111111111'
    delivery(client).ensure_beta_review_information
    assert_equal '+441111111111',client.review_contact['contactPhone']
    assert_equal 'Owner',client.review_contact['contactFirstName']
  end
  def test_preserves_alpha_owner_contact
    client=FakeClient.new; client.review_contact['contactEmail']='alpha@example.com'
    delivery(client).ensure_beta_review_information
    assert_equal 'alpha@example.com',client.review_contact['contactEmail']
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

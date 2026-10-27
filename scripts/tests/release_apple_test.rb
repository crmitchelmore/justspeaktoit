require 'minitest/autorun'
require_relative '../release-apple'

class ReleaseAppleTest < Minitest::Test
  class FakeClient
    attr_accessor :processing, :beta_state, :review_busy, :assigned, :bundle_id
    attr_reader :posts, :calls
    attr_accessor :auto_notify, :observe_notify_write, :detail_id, :detail_states
    attr_accessor :beta_locales, :review_contact, :stable_contact, :store_contact
    def initialize
      @detail_states=[]
      @calls=[]; @auto_notify=false; @observe_notify_write=true; @detail_id='beta-detail-not-build-id'
      @bundle_id='com.justspeaktoit.ios.alpha'; @processing='VALID'; @beta_state='READY_FOR_BETA_SUBMISSION'; @review_busy=false; @assigned=false; @posts=[]; @beta_locales=[]; @review_contact={'contactFirstName'=>'Owner','contactLastName'=>'Tester','contactPhone'=>'+441234567890','contactEmail'=>'owner@example.com'}; @stable_contact=@review_contact.dup; @store_contact=@review_contact.dup
    end
    def build
      {'id'=>'apple-build','attributes'=>{'processingState'=>processing,'expired'=>false,'expirationDate'=>'2026-12-01T00:00:00Z'}}
    end
    def get(path)
      @calls << {method: :get, path: path}
      return {'data'=>{'id'=>'store-review','attributes'=>store_contact}} if path == '/v1/appStoreVersions/stable-version/appStoreReviewDetail'
      raise 'Unexpected Store review source' if path.end_with?('/appStoreReviewDetail')
      return {'data'=>{'id'=>'review','attributes'=>path.include?('6810300888') ? review_contact : stable_contact}} if path.end_with?('/betaAppReviewDetail')
      return {'data'=>{'attributes'=>{'bundleId'=>bundle_id}}} if path.start_with?('/v1/apps/')
      # Group access, notification configuration and Apple state are independent.
      state=detail_states.empty? ? beta_state : detail_states.shift
      {'data'=>{'id'=>detail_id,'attributes'=>{'externalBuildState'=>state,'autoNotifyEnabled'=>auto_notify}}}
    end
    def list(path)
      @calls << {method: :list, path: path}
      return [{'id'=>'stable-version'}] if path == '/v1/apps/6758528955/appStoreVersions?limit=200'
      raise 'Unexpected Store app source' if path.include?('/appStoreVersions')
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
      @calls << {method: :post, path: path, body: body}
      @posts << path
      @beta_locales << {'id'=>'beta-locale', 'attributes'=>body[:data][:attributes].transform_keys(&:to_s)} if path == '/v1/betaAppLocalizations'
      @assigned=true if path.end_with?('/relationships/builds')
      {'data'=>{}}
    end
    def patch(path, body)
      @calls << {method: :patch, path: path, body: body}
      @auto_notify=body[:data][:attributes][:autoNotifyEnabled] if path.start_with?('/v1/buildBetaDetails/') && observe_notify_write
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
  def delivery(client, train: 'alpha', surface: 'ios')
    notes='Frozen notes'
    manifest={'train'=>train,'source'=>'a'*40,'tag'=>'alpha-build-1','surfaces'=>{surface=>{'version'=>'3.2.0','build'=>'1000.0.1','notes'=>notes,'notesHash'=>Digest::SHA256.hexdigest(notes),'storeNotes'=>notes,'storeNotesHash'=>Digest::SHA256.hexdigest(notes)}}}
    Delivery.new(client:client,manifest:manifest,surface:surface)
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
  def test_approved_group_assignment_does_not_manufacture_external_testing
    client=FakeClient.new;client.beta_state='BETA_APPROVED';d=delivery(client);d.distribute(wait_seconds:0)
    assert client.assigned
    assert_equal 'BETA_APPROVED',client.beta_state
    assert_equal 'beta_processing',d.receipts.last.first
    assert_equal 'BETA_APPROVED',d.receipts.last.last[:betaState]
    assert_equal ['https://testflight.apple.com/join/example'],d.receipts.last.last[:publicLinks]
    assert_empty notify_patches(client)
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
  def test_new_alpha_enables_and_observes_notification_before_review_on_both_surfaces
    {'ios'=>'com.justspeaktoit.ios.alpha', 'mac-store'=>'com.justspeaktoit.mac.appstore.alpha'}.each do |surface,bundle|
      client=FakeClient.new; client.bundle_id=bundle
      d=delivery(client,surface:surface); d.distribute(wait_seconds:0)
      assert_equal [{method: :patch, path: '/v1/buildBetaDetails/beta-detail-not-build-id', body: {
        data: {type: 'buildBetaDetails', id: 'beta-detail-not-build-id', attributes: {autoNotifyEnabled: true}}}
      }],notify_patches(client)
      patch_index=client.calls.index(notify_patches(client).first)
      review_index=client.calls.index{|call| call[:path]=='/v1/betaAppReviewSubmissions'}
      observed=client.calls.each_index.select{|index| index>patch_index && index<review_index &&
        client.calls[index][:method]==:get && client.calls[index][:path]=='/v1/builds/apple-build/buildBetaDetail'}
      refute_empty observed,'Flag readback must precede review submission'
      assert_equal true,client.auto_notify
      assert_equal 'READY_FOR_BETA_SUBMISSION',client.beta_state,'Configuration is not an Apple state transition'
      assert_equal 'beta_review_pending',d.receipts.last.first
      refute client.assigned
      refute_includes client.posts,'/v1/buildBetaNotifications'
    end
  end

  def test_already_enabled_flag_is_not_patched_and_later_server_state_is_independent
    client=FakeClient.new; client.auto_notify=true
    d=delivery(client); d.distribute(wait_seconds:0)
    client.beta_state='WAITING_FOR_BETA_REVIEW' # Explicit independent server response, not a POST side effect.
    d.distribute(wait_seconds:0)
    assert_empty notify_patches(client)
    assert_equal 1,client.posts.count('/v1/betaAppReviewSubmissions')
    assert_equal 'beta_review_pending',d.receipts.last.first
    refute client.assigned
  end

  def test_false_or_missing_flag_readback_refuses_review_submission
    [false,nil].each do |observed|
      client=FakeClient.new; client.auto_notify=observed; client.observe_notify_write=false
      d=delivery(client)
      error=assert_raises(RuntimeError){d.distribute(wait_seconds:0)}
      assert_match 'notification setting was not observed',error.message
      refute_includes client.posts,'/v1/betaAppReviewSubmissions'
      refute client.assigned
      observed.nil? ? assert_nil(client.auto_notify) : assert_equal(observed,client.auto_notify)
      assert_nil d.receipts
    end
  end

  def test_missing_detail_identity_refuses_notification_patch_and_review
    [nil,'','   '].each do |identity|
      client=FakeClient.new; client.detail_id=identity
      assert_raises(RuntimeError){delivery(client).distribute(wait_seconds:0)}
      assert_empty notify_patches(client)
      refute_includes client.posts,'/v1/betaAppReviewSubmissions'
    end
  end

  def test_notification_auth_and_validation_errors_are_not_swallowed_as_review_pending
    [401,403,422].each do |status|
      client=FakeClient.new
      client.define_singleton_method(:patch) do |path,body|
        raise IOSProfileBootstrap::ApiError.new('synthetic flag error',status:status) if path.start_with?('/v1/buildBetaDetails/')
        super(path,body)
      end
      d=delivery(client)
      error=assert_raises(IOSProfileBootstrap::ApiError){d.distribute(wait_seconds:0)}
      assert_equal status,error.status
      refute_includes client.posts,'/v1/betaAppReviewSubmissions'
      assert_nil d.receipts
    end
  end

  def test_busy_review_slot_has_no_automatic_notification_write
    client=FakeClient.new; client.review_busy=true
    d=delivery(client); d.distribute(wait_seconds:0)
    assert_equal 'waiting_for_beta_review_slot',d.receipts.last.first
    assert_empty notify_patches(client)
    assert_equal false,client.auto_notify
    refute_includes client.posts,'/v1/betaAppReviewSubmissions'
  end

  def test_approved_build_remains_pending_regardless_of_notification_flag
    [false,true].each do |flag|
      client=FakeClient.new; client.beta_state='BETA_APPROVED'; client.auto_notify=flag; client.assigned=true
      d=delivery(client); 2.times{d.distribute(wait_seconds:0)}
      assert_equal 'beta_processing',d.receipts.last.first
      assert_equal 'BETA_APPROVED',d.receipts.last.last[:betaState]
      assert_equal flag,client.auto_notify
      assert_empty notify_patches(client)
      refute client.posts.any?{|path| path.end_with?('/relationships/builds')}
      refute_includes client.posts,'/v1/buildBetaNotifications'
    end
  end

  def test_existing_ready_states_preserve_verified_contract_without_activation_writes
    %w[IN_BETA_TESTING READY_FOR_BETA_TESTING].each do |state|
      client=FakeClient.new; client.beta_state=state
      d=delivery(client); 2.times{d.distribute(wait_seconds:0)}
      assert_equal 'verified',d.receipts.last.first
      assert_equal state,d.receipts.last.last[:betaState]
      assert_equal ['public-alpha'],d.receipts.last.last[:groups]
      assert_equal 1,client.posts.count('/v1/betaGroups/public-alpha/relationships/builds')
      assert_empty notify_patches(client)
      refute_includes client.posts,'/v1/buildBetaNotifications'
    end
  end

  def test_only_explicit_later_server_response_can_change_approved_receipt_to_ready
    client=FakeClient.new; client.beta_state='BETA_APPROVED'; client.auto_notify=true
    d=delivery(client); d.distribute(wait_seconds:0)
    assert_equal 'beta_processing',d.receipts.last.first
    client.beta_state='READY_FOR_BETA_TESTING' # Independent server snapshot, never derived from assignment/flag.
    d.distribute(wait_seconds:0)
    assert_equal 'verified',d.receipts.last.first
    assert_equal 1,client.posts.count('/v1/betaGroups/public-alpha/relationships/builds')
    assert_empty notify_patches(client)
  end

  def test_stable_cannot_enable_notification_even_through_the_helper
    client=FakeClient.new; client.bundle_id=client.bundle_id.delete_suffix('.alpha')
    d=delivery(client,train:'stable')
    assert_raises(RuntimeError){d.ensure_automatic_beta_notification('apple-build')}
    assert_empty client.calls.select{|call| call[:method]==:patch || call[:method]==:post}
  end

  def test_stale_initial_ready_state_is_refreshed_before_any_notification_patch
    ['BETA_APPROVED',nil,'WAITING_FOR_BETA_REVIEW'].each do |latest|
      client=FakeClient.new; client.detail_states=['READY_FOR_BETA_SUBMISSION',latest]
      d=delivery(client)
      error=assert_raises(RuntimeError){d.distribute(wait_seconds:0)}
      assert_match 'readiness changed',error.message
      assert_empty notify_patches(client)
      refute_includes client.posts,'/v1/betaAppReviewSubmissions'
      refute client.assigned
      assert_equal false,client.auto_notify
    end
  end

  def test_changed_state_after_flag_write_is_not_used_to_submit_review
    client=FakeClient.new
    client.detail_states=['READY_FOR_BETA_SUBMISSION','READY_FOR_BETA_SUBMISSION','BETA_APPROVED']
    error=assert_raises(RuntimeError){delivery(client).distribute(wait_seconds:0)}
    assert_match 'notification setting was not observed',error.message
    assert_equal 1,notify_patches(client).length
    refute_includes client.posts,'/v1/betaAppReviewSubmissions'
  end

  def test_readback_detail_identity_must_match_the_observed_patch_resource
    client=FakeClient.new
    reads=0
    client.define_singleton_method(:get) do |path|
      if path=='/v1/builds/apple-build/buildBetaDetail'
        reads+=1
        self.detail_id='different-detail' if reads==3
      end
      super(path)
    end
    assert_raises(RuntimeError){delivery(client).distribute(wait_seconds:0)}
    assert_equal '/v1/buildBetaDetails/beta-detail-not-build-id',notify_patches(client).first[:path]
    refute_includes client.posts,'/v1/betaAppReviewSubmissions'
  end

  def test_missing_detail_readback_data_refuses_review_without_inventing_enabled_state
    client=FakeClient.new
    reads=0
    client.define_singleton_method(:get) do |path|
      if path=='/v1/builds/apple-build/buildBetaDetail'
        reads+=1
        return {'data'=>nil} if reads==3
      end
      super(path)
    end
    error=assert_raises(RuntimeError){delivery(client).distribute(wait_seconds:0)}
    assert_match 'notification setting was not observed',error.message
    refute_includes client.posts,'/v1/betaAppReviewSubmissions'
  end

  private

  def notify_patches(client)
    client.calls.select{|call| call[:method]==:patch && call[:path].start_with?('/v1/buildBetaDetails/')}
  end
end

# frozen_string_literal: true

require 'json'
require 'digest'
require 'uri'

module AppleRelease
  # Notes-only operations. GET/PATCH is not atomic: the second read detects
  # observed conflicts; exact readback is required before the caller proceeds.
  class MacReviewNotes
    class Error < StandardError; end

    EDITABLE_STATES = %w[REJECTED PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED].freeze
    MAX_NOTES_LENGTH = 4000
    ROOT = File.expand_path('..', __dir__)
    CANONICAL = <<~TEXT.freeze
      The macOS app includes an optional "Send to Mac" receiver using com.apple.security.network.server. It is off by default.

      On the Mac, open Settings > General > Send to Mac and enable "Enable Send to Mac": this starts a Network.framework TCP NWListener, advertises %{service}, and displays a pairing code. Turning the setting off stops the listener. This listener exchanges paired transcript protocol messages; it does not serve web pages or transfer files. Outbound provider requests use network.client separately.

      A shipping iOS sender screen is not currently available; these steps describe only the Mac receiver, not verified end-to-end iPhone delivery.
    TEXT

    def initialize(client:, train:)
      raise Error, 'invalid_train' unless %w[alpha stable].include?(train)
      @client, @train = client, train
      pipeline = JSON.parse(File.read(File.join(ROOT, 'Config/ReleasePipeline.json')))
      config = JSON.parse(File.read(File.join(ROOT, 'Sources/SpeakCore/Resources/ReleaseTrains.json'))).fetch(train)
      @app = pipeline.fetch('apple').fetch(train).fetch('mac-store')
      @bundle = config.fetch('storeMacBundleIdentifier')
      @canonical = format(CANONICAL, service: config.fetch('transportServiceType')).strip
    end

    def audit(version_id: nil)
      safely do
        require_stable
        verify_app
        versions = mac_versions
        versions = [selected_version(versions, version_id)] if version_id
        versions.map { |version| public_record(read_version(version)) }
      end
    end

    def repair(version_id:, expected_notes_hash:)
      safely do
        require_stable
        raise Error, 'invalid_expected_notes_hash' unless expected_notes_hash&.match?(/\A[0-9a-f]{64}\z/)
        verify_app
        first = read_version(selected_version(mac_versions, version_id))
        raise Error, 'notes_hash_conflict' unless first[:hash] == expected_notes_hash
        public_record(ensure_version_notes(first))
      end
    end

    def ensure_stable(version_id)
      safely do
        require_stable
        verify_app
        ensure_version_notes(read_version(selected_version(mac_versions, version_id)))
        nil
      end
    end

    def ensure_beta
      safely do
        raise Error, 'alpha_required' unless @train == 'alpha'
        verify_app
        path = "/v1/apps/#{@app}/betaAppReviewDetail?fields[betaAppReviewDetails]=notes"
        first = read_detail(path, 'betaAppReviewDetails')
        expected = append(first[:notes])
        second = read_detail(path, 'betaAppReviewDetails')
        raise Error, 'notes_read_conflict' unless same_detail?(first, second)
        write_notes(first, expected) unless expected == first[:notes]
        observed = read_detail(path, 'betaAppReviewDetails')
        verify_notes(first, observed, expected)
        nil
      end
    end

    private

    def safely
      yield
    rescue Error
      raise
    rescue StandardError
      # Apple errors can include existing notes or other private metadata.
      raise Error, 'apple_review_notes_request_failed', cause: nil
    end

    def require_stable
      raise Error, 'stable_required' unless @train == 'stable'
    end

    def verify_app
      data = @client.get("/v1/apps/#{@app}?fields[apps]=bundleId").fetch('data')
      unless data['id'] == @app && data['type'] == 'apps' && data.dig('attributes', 'bundleId') == @bundle
        raise Error, 'mac_app_identity_mismatch'
      end
    end

    def mac_versions
      query = URI.encode_www_form('filter[platform]' => 'MAC_OS',
        'fields[appStoreVersions]' => 'platform,versionString,appStoreState', 'limit' => 200)
      @client.list("/v1/apps/#{@app}/appStoreVersions?#{query}")
    end

    def selected_version(versions, id)
      raise Error, 'version_id_required' unless id.is_a?(String) && !id.empty?
      matches = versions.select { |version| version['id'] == id }
      raise Error, 'selected_mac_version_missing_or_ambiguous' unless matches.length == 1
      matches.first
    end

    def read_version(version)
      attrs = version.fetch('attributes')
      raise Error, 'mac_version_identity_mismatch' unless attrs['platform'] == 'MAC_OS'
      id = version.fetch('id')
      detail = read_detail("/v1/appStoreVersions/#{id}/appStoreReviewDetail?fields[appStoreReviewDetails]=notes",
        'appStoreReviewDetails', allow_missing: true)
      detail.merge(version_id: id, version: attrs.fetch('versionString'), state: attrs.fetch('appStoreState'))
    end

    def read_detail(path, type, allow_missing: false)
      detail = @client.get(path).fetch('data')
      return {id: nil, type: type, notes: nil, hash: nil} if allow_missing && detail.nil?
      unless detail.is_a?(Hash) && detail['type'] == type && detail['id'].is_a?(String) && !detail['id'].empty?
        raise Error, 'review_detail_identity_missing'
      end
      notes = detail.fetch('attributes').fetch('notes', nil)
      raise Error, 'invalid_notes_type' unless notes.nil? || notes.is_a?(String)
      notes = notes.to_s
      {id: detail['id'], type: type, notes: notes, hash: Digest::SHA256.hexdigest(notes)}
    end

    def ensure_version_notes(first)
      raise Error, 'mac_version_not_editable' unless EDITABLE_STATES.include?(first[:state])
      raise Error, 'review_detail_missing' unless first[:id]
      expected = append(first[:notes])
      second = read_version(selected_version(mac_versions, first[:version_id]))
      unless same_detail?(first, second) && first.values_at(:version, :state) == second.values_at(:version, :state)
        raise Error, 'notes_read_conflict'
      end
      write_notes(first, expected) unless expected == first[:notes]
      observed = read_version(selected_version(mac_versions, first[:version_id]))
      verify_notes(first, observed, expected)
      unless first.values_at(:version, :state) == observed.values_at(:version, :state)
        raise Error, 'version_state_readback_changed'
      end
      observed
    end

    def append(notes)
      return notes if notes.include?(@canonical)
      result = notes.empty? ? @canonical : notes + "\n\n" + @canonical
      raise Error, 'review_notes_capacity_exceeded' if result.length > MAX_NOTES_LENGTH
      result
    end

    def same_detail?(first, second)
      first.values_at(:id, :type, :notes) == second.values_at(:id, :type, :notes)
    end

    def write_notes(detail, notes)
      @client.patch("/v1/#{detail[:type]}/#{detail[:id]}", data: {
        type: detail[:type], id: detail[:id], attributes: {notes: notes}})
    end

    def verify_notes(first, observed, expected)
      unless first.values_at(:id, :type) == observed.values_at(:id, :type) && observed[:notes] == expected
        raise Error, 'review_notes_write_not_observed'
      end
    end

    def public_record(record)
      {version_id: record[:version_id], version: record[:version], state: record[:state],
       review_resource_id: record[:id], notes_sha256: record[:hash], notes_length: record[:notes]&.length,
       canonical_present: record[:notes].to_s.include?(@canonical)}
    end
  end
end

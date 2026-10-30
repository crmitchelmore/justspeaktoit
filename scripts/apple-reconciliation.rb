# frozen_string_literal: true
require 'time'
require 'json'
require 'digest'
require 'tempfile'

module AppleRelease
  PENDING_APPLE_RECEIPTS = %w[processing waiting_for_beta_review_slot beta_review_pending beta_processing].freeze
  APPLE_RECEIPT_STATES = (PENDING_APPLE_RECEIPTS + %w[verified invalid beta_rejected]).freeze
  # The Mac App Store surface is retired; historical mac-store receipts are ignored.
  APPLE_SURFACES = %w[ios].freeze
  RETIRED_RECEIPT_NAMES = %w[mac-store-receipt.json].freeze
  APPLE_RECEIPT_NAMES = APPLE_SURFACES.map { |surface| "#{surface}-receipt.json" }.freeze
  class ReconciliationInputError < StandardError; end

  # Only GitHub's existing persisted observations are read here. No Apple client
  # is constructed until the complete snapshot and all consumed identities pass.
  class ReconciliationReader
    MAX_JSON_BYTES = 65_536
    MAX_METADATA_BYTES = 4 * 1024 * 1024
    REPO = 'crmitchelmore/justspeaktoit'

    def initialize(command: nil)
      @command = command
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
    end

    def releases
      projection = '.[] | select(.tag_name == "alpha-latest" or (.tag_name | startswith("alpha-build-"))) | '
      projection += '{tag_name, assets: [.assets[] | select(.name == "alpha-pointer.json" or '
      projection += '.name == "ios-receipt.json") | {id, name, size}]} | tojson'
      raw = read(['gh', 'api', '--paginate', "repos/#{REPO}/releases?per_page=100", '--jq', projection], MAX_METADATA_BYTES)
      raw.lines.reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
    rescue StandardError
      raise ReconciliationInputError, 'Cannot acquire complete release observation metadata'
    end

    def asset(asset)
      unless asset.is_a?(Hash) && asset['id'].is_a?(Integer) && asset['id'].positive? &&
          asset['size'].is_a?(Integer) && asset['size'].between?(1, MAX_JSON_BYTES)
        raise ReconciliationInputError, 'Invalid release observation asset metadata'
      end
      JSON.parse(read(['gh', 'api', "repos/#{REPO}/releases/assets/#{asset.fetch('id')}",
        '-H', 'Accept: application/octet-stream'], MAX_JSON_BYTES))
    rescue StandardError
      raise ReconciliationInputError, 'Cannot acquire release observation asset'
    end

    private

    def read(arguments, limit)
      raw = @command ? @command.call(arguments, limit) : capture(arguments, limit)
      raise ReconciliationInputError unless raw.is_a?(String) && raw.bytesize <= limit
      raw
    end

    # Bound both output and time without leaving a timed-out gh process behind.
    # Temporary observations and stderr are private and are never printed.
    def capture(arguments, limit)
      remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise ReconciliationInputError unless remaining.positive?
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + [remaining, 30].min
      Tempfile.create('apple-observation-out') do |out|
        Tempfile.create('apple-observation-error') do |err|
          pid = Process.spawn(*arguments, out: out, err: err, pgroup: true, rlimit_fsize: limit + 1)
          reaped = false
          begin
            loop do
              ended = Process.waitpid2(pid, Process::WNOHANG)
              if ended
                reaped = true
                raise ReconciliationInputError unless ended.last.success?
                break
              end
              raise ReconciliationInputError if out.size > limit || err.size > 4096 ||
                Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              sleep 0.02
            end
            raise ReconciliationInputError if out.size > limit || err.size > 4096
            out.rewind
            out.read(limit + 1)
          ensure
            unless reaped
              begin
                Process.kill('KILL', -pid)
              rescue Errno::ESRCH
                # The owned process may have exited just before cancellation.
              end
              Process.waitpid(pid)
            end
          end
        end
      end
    end
  end

  def self.reconciliation_state(manifests, reader: ReconciliationReader.new, now: Time.now)
    alpha = manifests.select { |manifest| manifest.fetch('train') == 'alpha' }
    by_tag = {}
    alpha.each do |manifest|
      tag = manifest.fetch('tag')
      raise ReconciliationInputError unless tag.is_a?(String) && tag.match?(/\Aalpha-build-[1-9][0-9]*\z/) &&
        manifest['ordinal'].is_a?(Integer) && tag == "alpha-build-#{manifest['ordinal']}" && !by_tag.key?(tag) &&
        manifest['source'].is_a?(String) && manifest['source'].match?(/\A[0-9a-f]{40}\z/) &&
        manifest['build'].is_a?(String) && manifest['build'].match?(/\A[0-9]+\z/)
      Time.iso8601(manifest.fetch('createdAt'))
      APPLE_SURFACES.each do |surface|
        item = manifest.fetch('surfaces').fetch(surface)
        raise ReconciliationInputError unless item.is_a?(Hash) && item['build'].is_a?(String) &&
          item['build'].match?(/\A[0-9]+(?:\.[0-9]+)*\z/) && item['notes'].is_a?(String) &&
          item['notesHash'] == Digest::SHA256.hexdigest(item['notes'])
      end
      by_tag[tag] = manifest
    end
    releases = reader.releases
    raise ReconciliationInputError unless releases.is_a?(Array)
    seen = {}
    current = nil
    pending = []
    releases.each do |release|
      raise ReconciliationInputError unless release.is_a?(Hash) && release['tag_name'].is_a?(String) &&
        release['assets'].is_a?(Array) && !seen.key?(release['tag_name'])
      tag = release.fetch('tag_name')
      seen[tag] = true
      next unless tag == 'alpha-latest' || by_tag.key?(tag)
      # Expired historical receipt contents are irrelevant to scheduled work.
      next if tag != 'alpha-latest' && Time.iso8601(by_tag.fetch(tag).fetch('createdAt')) < now - 90 * 86_400
      assets = {}
      release.fetch('assets').each do |asset|
        next if asset.is_a?(Hash) && RETIRED_RECEIPT_NAMES.include?(asset['name'])
        raise ReconciliationInputError unless asset.is_a?(Hash) && asset['name'].is_a?(String) &&
          (APPLE_RECEIPT_NAMES + ['alpha-pointer.json']).include?(asset['name']) && !assets.key?(asset['name'])
        assets[asset.fetch('name')] = asset
      end
      if tag == 'alpha-latest'
        pointer = reader.asset(assets.fetch('alpha-pointer.json'))
        raise ReconciliationInputError unless pointer.is_a?(Hash)
        manifest = by_tag.fetch(pointer.fetch('tag'))
        raise ReconciliationInputError unless pointer['source'] == manifest.fetch('source') &&
          pointer['build'] == manifest.fetch('build')
        current = manifest.fetch('tag')
      else
        manifest = by_tag.fetch(tag)
        APPLE_RECEIPT_NAMES.each do |name|
          next unless assets.key?(name) # Proven metadata absence, never a failed read.
          receipt = reader.asset(assets.fetch(name))
          item = manifest.fetch('surfaces').fetch(name.delete_suffix('-receipt.json'))
          raise ReconciliationInputError unless receipt.is_a?(Hash) && receipt['source'] == manifest.fetch('source') &&
            receipt['build'] == item.fetch('build') && receipt['notesHash'] == item.fetch('notesHash') &&
            APPLE_RECEIPT_STATES.include?(receipt['status'])
          Time.iso8601(receipt['expirationDate']) unless receipt['expirationDate'].nil?
          pending << tag if PENDING_APPLE_RECEIPTS.include?(receipt.fetch('status'))
        end
      end
    end
    {current_alpha: current, pending_alphas: pending.uniq}
  rescue StandardError
    raise ReconciliationInputError, 'Release observation snapshot is unavailable or inconsistent'
  end

  # Allocation does not supersede a bound current or pending Apple boundary.
  # The existing ordinary ledger-age policy and explicit historical path remain.
  def self.reconciliation_manifests(manifests, tag: nil, now: Time.now, state: nil, observe: nil)
    if tag
      selected = manifests.find { |manifest| manifest.fetch('tag') == tag }
      raise 'Unknown release manifest' unless selected
      return [selected]
    end
    raise ReconciliationInputError, 'Release observation snapshot is required' unless state.is_a?(Hash) &&
      state.keys.sort == %i[current_alpha pending_alphas].sort && state[:pending_alphas].is_a?(Array)
    stable = manifests.select { |manifest| manifest.fetch('train') == 'stable' }
    alpha = manifests.select { |manifest| manifest.fetch('train') == 'alpha' }
    selected = stable.map { |manifest| manifest['selectedAlpha'] }.compact
    newest = alpha.max_by { |manifest| manifest.fetch('ordinal') }
    selected << newest.fetch('tag') if newest
    boundaries = [state[:current_alpha], *state[:pending_alphas]].compact.uniq
    known = alpha.map { |manifest| manifest.fetch('tag') }
    raise ReconciliationInputError, 'Release observation boundary is unknown' unless (boundaries - known).empty?
    stable_selected = selected.dup
    selected.concat(boundaries)
    expired = {expired_alpha: 0, expired_current_alpha: 0, expired_stable_selected_alpha: 0}
    active_alpha = alpha.select do |manifest|
      eligible = Time.parse(manifest.fetch('createdAt')) >= now - 90 * 86_400
      unless eligible
        expired[:expired_alpha] += 1
        expired[:expired_current_alpha] += 1 if state[:current_alpha] == manifest.fetch('tag')
        expired[:expired_stable_selected_alpha] += 1 if stable_selected.include?(manifest.fetch('tag')) &&
          stable.any? { |candidate| candidate['selectedAlpha'] == manifest.fetch('tag') }
      end
      selected.include?(manifest.fetch('tag')) && eligible
    end
    expired.each { |category, count| observe.call(category, count) if count.positive? } if observe
    (active_alpha + stable).sort_by { |manifest| [manifest.fetch('train'), -manifest.fetch('ordinal')] }
  end
end

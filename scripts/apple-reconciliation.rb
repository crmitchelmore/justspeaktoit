# frozen_string_literal: true
require 'time'

module AppleRelease
  # Old Alpha uploads cannot become the current release. Keep the newest Alpha
  # plus the Alpha selected by each frozen Stable candidate, and every Stable
  # candidate (each may still advance a separate App Store publication boundary).
  def self.reconciliation_manifests(manifests, tag: nil, now: Time.now)
    if tag
      selected = manifests.find { |manifest| manifest.fetch('tag') == tag }
      raise "Unknown release manifest: #{tag}" unless selected
      return [selected]
    end
    stable = manifests.select { |manifest| manifest.fetch('train') == 'stable' }
    alpha = manifests.select { |manifest| manifest.fetch('train') == 'alpha' }
    selected = stable.map { |manifest| manifest['selectedAlpha'] }.compact
    newest = alpha.max_by { |manifest| manifest.fetch('ordinal') }
    selected << newest.fetch('tag') if newest
    active_alpha = alpha.select do |manifest|
      selected.include?(manifest.fetch('tag')) && Time.parse(manifest.fetch('createdAt')) >= now - 90 * 86_400
    end
    (active_alpha + stable).sort_by { |manifest| [manifest.fetch('train'), -manifest.fetch('ordinal')] }
  end
end

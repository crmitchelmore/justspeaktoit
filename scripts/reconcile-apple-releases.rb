#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative 'release-apple'
require 'open3'
output, status = Open3.capture2('git','for-each-ref','--format=%(refname:short)','refs/tags/alpha-build-*','refs/tags/stable-candidate-*')
abort 'Cannot read release ledger' unless status.success?
require_relative 'apple-reconciliation'
failures=[]
tag = ENV['RECONCILE_TAG'].to_s.strip
tags = output.lines.map(&:strip)
tags.select! { |candidate| candidate == tag } unless tag.empty?
manifests=tags.map do |tag|
  data, result = Open3.capture2('git','for-each-ref','--format=%(contents)',"refs/tags/#{tag}")
  abort "Cannot read release manifest: #{tag}" unless result.success?
  JSON.parse(data)
end
begin
  now = Time.now
  state = AppleRelease.reconciliation_state(manifests, now: now) if tag.empty?
  selected = AppleRelease.reconciliation_manifests(manifests, tag: tag.empty? ? nil : tag, state: state, now: now,
    observe: ->(category, count) { warn "Ordinary Alpha ledger-age policy: #{category}=#{count}" })
rescue AppleRelease::ReconciliationInputError
  abort 'Apple reconciliation observations are unavailable or inconsistent; no Apple work started'
end
client = AppleRelease::Client.new
selected.each do |manifest|
  tag = manifest.fetch('tag')
  AppleRelease::APPLE_SURFACES.each do |surface|
    begin
      delivery=AppleRelease::Delivery.new(client:client,manifest:manifest,surface:surface)
      delivery.distribute(wait_seconds:0) if delivery.build
      delivery.observe_publication if manifest['train'] == 'stable'
    rescue StandardError => error
      warn "#{tag} #{surface}: #{error.message}"
      failures << "#{tag} #{surface}"
    end
  end
end
abort "Apple reconciliation needs attention: #{failures.join(', ')}" unless failures.empty?

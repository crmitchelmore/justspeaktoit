#!/usr/bin/env ruby
# frozen_string_literal: true
# Keeps owner-nominated testers in the iOS Alpha "Public Alpha" external group.
# Tester addresses come only from the TESTFLIGHT_TESTER_EMAILS secret; output
# and errors carry counts and Apple states, never addresses.
require_relative 'release-apple'

module AppleRelease
  class TesterAccess
    GROUP = 'Public Alpha'
    INVITED = %w[INVITED ACCEPTED INSTALLED].freeze
    LIVE_BUILD_STATES = %w[IN_BETA_TESTING WAITING_FOR_BETA_REVIEW].freeze
    EMAIL = /\A[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+\z/

    class InputError < StandardError; end

    def self.parse_emails(raw)
      entries = raw.to_s.split(',').map { |entry| entry.strip.downcase }.reject(&:empty?)
      raise InputError, 'No tester addresses configured' if entries.empty?
      invalid = entries.count { |entry| !entry.match?(EMAIL) }
      raise InputError, "#{invalid} configured tester entries are not email addresses" if invalid.positive?
      entries.uniq
    end

    def self.redact(text, emails = [])
      redacted = text.to_s
      emails.each { |email| redacted = redacted.gsub(/#{Regexp.escape(email)}/i, '[redacted]') }
      # Query strings carry addresses percent-encoded; Apple bodies may echo them.
      redacted.gsub(/[^\s"'@=&?,;]+(?:@|%40)[^\s"'&,;]+/i, '[redacted]')
    end

    attr_reader :app

    def initialize(client:, pipeline: JSON.parse(File.read('Config/ReleasePipeline.json')),
                   trains: JSON.parse(File.read('Sources/SpeakCore/Resources/ReleaseTrains.json')),
                   log: ->(line) { puts line })
      @client, @log = client, log
      @app = pipeline.fetch('apple').fetch('alpha').fetch('ios')
      bundle = trains.fetch('alpha').fetch('iosBundleIdentifier')
      actual = @client.get("/v1/apps/#{@app}").dig('data', 'attributes', 'bundleId')
      raise 'App record belongs to different identity' unless actual == bundle
    end

    def group
      @group ||= begin
        groups = @client.list("/v1/apps/#{@app}/betaGroups?limit=200").select do |candidate|
          candidate.dig('attributes', 'name') == GROUP && !candidate.dig('attributes', 'isInternalGroup')
        end
        raise "Expected exactly one external #{GROUP} group, found #{groups.length}" unless groups.length == 1
        groups.first
      end
    end

    # Idempotent: members are left alone; existing account testers are linked;
    # unknown addresses are created directly in the group.
    def ensure_testers(emails)
      counts = {already: 0, linked: 0, created: 0, invited: 0, invite_pending: 0}
      emails.each do |email|
        tester = member(email)
        if tester
          counts[:already] += 1
          linked = false
        else
          tester, how = link_or_create(email)
          counts[how] += 1
          linked = how == :linked
        end
        # A linked account tester's state can reflect another app, so invite it.
        next if !linked && INVITED.include?(tester.dig('attributes', 'state'))
        counts[invite(tester) ? :invited : :invite_pending] += 1
      end
      @log.call("Testers: #{emails.length} configured, #{counts[:already]} already in #{GROUP}, " \
                "#{counts[:linked]} linked, #{counts[:created]} created, #{counts[:invited]} invitations sent, " \
                "#{counts[:invite_pending]} invitations pending")
      counts
    end

    def latest_build
      query = URI.encode_www_form('filter[app]' => @app, 'sort' => '-uploadedDate', 'limit' => 10)
      builds = @client.get("/v1/builds?#{query}").fetch('data')
      found = builds.find { |b| b.dig('attributes', 'processingState') == 'VALID' && !b.dig('attributes', 'expired') }
      return nil unless found
      detail = @client.get("/v1/builds/#{found.fetch('id')}/buildBetaDetail").fetch('data')
      assigned = @client.list("/v1/betaGroups/#{group.fetch('id')}/builds?limit=200").any? { |b| b['id'] == found['id'] }
      {id: found['id'], number: found.dig('attributes', 'version'), uploaded: found.dig('attributes', 'uploadedDate'),
       expires: found.dig('attributes', 'expirationDate'), state: detail.dig('attributes', 'externalBuildState'),
       assigned: assigned}
    end

    def recent?(build, now: Time.now, days: 30)
      return false unless build && build[:uploaded]
      Time.parse(build[:uploaded]) >= now - days * 86_400 &&
        (build[:expires].nil? || Time.parse(build[:expires]) > now + 7 * 86_400)
    end

    def verify(emails)
      members = emails.map { |email| member(email) }
      missing = members.count(&:nil?)
      uninvited = members.compact.count { |tester| !INVITED.include?(tester.dig('attributes', 'state')) }
      build = latest_build
      problems = []
      problems << "#{missing} configured testers are not in #{GROUP}" if missing.positive?
      problems << "#{uninvited} testers have no invitation yet" if uninvited.positive?
      if build.nil?
        problems << 'No valid unexpired iOS Alpha build'
      else
        @log.call("Latest iOS Alpha build #{build[:number]}: #{build[:state]}, " \
                  "#{build[:assigned] ? 'assigned to' : 'not assigned to'} #{GROUP}")
        problems << "Build #{build[:number]} is #{build[:state]}" unless LIVE_BUILD_STATES.include?(build[:state])
        if build[:state] == 'IN_BETA_TESTING' && !build[:assigned]
          problems << "Build #{build[:number]} is not assigned to #{GROUP}"
        end
      end
      @log.call("Verified #{emails.length - missing}/#{emails.length} testers in #{GROUP}, " \
                "#{emails.length - missing - uninvited} invited")
      {build: build, problems: problems}
    end

    private

    def testers(filters)
      query = URI.encode_www_form(filters.merge('limit' => 10))
      @client.get("/v1/betaTesters?#{query}").fetch('data')
    end

    def member(email)
      testers('filter[email]' => email, 'filter[betaGroups]' => group.fetch('id')).first
    end

    def link_or_create(email)
      existing = testers('filter[email]' => email).first
      unless existing
        begin
          @client.post('/v1/betaTesters', data: {type: 'betaTesters', attributes: {email: email},
            relationships: {betaGroups: {data: [{type: 'betaGroups', id: group.fetch('id')}]}}})
          return [member(email) || raise('Created tester was not observed in the group'), :created]
        rescue IOSProfileBootstrap::ConflictError
          # Created concurrently or already on the account: link it instead.
          existing = testers('filter[email]' => email).first
          raise 'Apple reported a tester conflict but no tester is visible' unless existing
        end
      end
      @client.post("/v1/betaGroups/#{group.fetch('id')}/relationships/betaTesters",
        data: [{type: 'betaTesters', id: existing.fetch('id')}])
      [member(email) || raise('Tester group membership was not observed'), :linked]
    end

    # Apple only invites once a build is testable; until then it stays pending
    # and the next run (or Apple's own group notification) completes it.
    def invite(tester)
      @client.post('/v1/betaTesterInvitations', data: {type: 'betaTesterInvitations', relationships: {
        app: AppleRelease.relationship('apps', @app), betaTester: AppleRelease.relationship('betaTesters', tester.fetch('id'))}})
      true
    rescue IOSProfileBootstrap::ApiError => error
      raise unless [409, 422].include?(error.status)
      false
    end
  end
end

if $PROGRAM_NAME == __FILE__
  emails = []
  begin
    emails = AppleRelease::TesterAccess.parse_emails(ENV['TESTFLIGHT_TESTER_EMAILS'])
    access = AppleRelease::TesterAccess.new(client: AppleRelease::Client.new)
    case ARGV.first
    when 'ensure'
      access.ensure_testers(emails)
    when 'status'
      build = access.latest_build
      recent = access.recent?(build)
      puts(build ? "Latest iOS Alpha build #{build[:number]}: #{build[:state]}" : 'No valid iOS Alpha build')
      if ENV['GITHUB_OUTPUT']
        File.open(ENV['GITHUB_OUTPUT'], 'a') do |file|
          file.puts("build=#{build&.fetch(:number)}", "state=#{build&.fetch(:state)}", "recent=#{recent}")
        end
      end
    when 'verify'
      result = access.verify(emails)
      if ENV['GITHUB_STEP_SUMMARY'] && result[:build]
        File.open(ENV['GITHUB_STEP_SUMMARY'], 'a') do |file|
          file.puts("iOS Alpha build #{result[:build][:number]}: #{result[:build][:state]}")
        end
      end
      abort "TestFlight access needs attention: #{result[:problems].join('; ')}" unless result[:problems].empty?
    else
      abort 'Usage: testflight-testers.rb ensure|status|verify'
    end
  rescue StandardError => error
    abort AppleRelease::TesterAccess.redact("#{error.class}: #{error.message}", emails)
  end
end

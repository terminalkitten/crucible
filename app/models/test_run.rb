class TestRun
  include Mongoid::Document

  MAX_DOCUMENT_SIZE = 16000000

  field :conformance
  field :destination_conformance
  field :date, type: DateTime
  field :last_updated, type: DateTime
  field :worker_id, type: String
  field :is_multiserver, type: Boolean, default: false
  field :status, type: String, default: "pending"
  field :supported_only, type: Boolean, default: false

  belongs_to :server, class_name: "Server", index: true
  belongs_to :destination_server, class_name:" Server"
  field :nightly, type: Boolean, default: false
  has_and_belongs_to_many :tests, inverse_of: nil
  has_many :test_results, autosave: true

  def add_tests(tests)
    self.tests.push(*tests)
    self.save
  end

  def execute()

    # tracks if another worker picks up this thread due to long execution time (but not crash)
    this_worker_id = rand(1000000).to_s

    return false unless ['pending', 'stalled'].include?(self.status)
    recovered_from_stall = self.status == 'stalled'
    first_test = true
    self.last_updated = DateTime.now
    self.worker_id = this_worker_id
    self.status = 'running'
    self.save

    client1 = FHIR::Client.new(self.server.url)
    client1.default_format = self.server.default_format if self.server.default_format
    if self.server.oauth_token_opts
      client1.client = self.server.get_oauth2_client
      if client1.client.nil?
        self.status = 'unauthorized'
        self.save

        return false
      end
      # If the token had to get refreshed, the server oauth details are probably out of sync here
      # So we'll reload the server to keep it in sync, since we save it later in this function
      self.server.reload
      client1.use_oauth2_auth = true
    end
    # client2 = FHIR::Client.new(result.test_run.destination_server.url) if result.test_run.is_multiserver
    # TODO: figure out multi server
    client2 = nil

    executor = Crucible::Tests::Executor.new(client1, client2)

    unless self.server.available?
      self.status = 'unavailable'
      self.save

      return false
    end

    # pull all the tests into memory with .map {} so that the cursor doesn't time out
    # sort because mongoid does not retain order using self.tests; only retains order when using test_ids
    self.tests.map {|n| n}.sort {|a, b| test_ids.index(a.id) <=> test_ids.index(b.id) }.each_with_index do |t, i|
      testrun_check = TestRun.find(self.id)

      # skip if this test has already been run
      if testrun_check.test_results.count > i
        Delayed::Worker.logger.info "Test #{i} already run by another worker (of #{testrun_check.test_results.count} already run), skipping."
        next
      end

      # stop work if the testrun was cancelled
      return false if testrun_check.status == 'cancelled'

      Rails.logger.info "\t #{i}/#{self.tests.length}: #{self.server.name}(#{self.server.url})"
      test = executor.find_test(t.title)
      val = nil
      result = TestResult.new
      result.test = t
      result.server = self.server
      result.has_run = true

      begin

        # Do not attempt to rerun this test if it caused a fatal error last time
        raise "Unrecoverable Crucibe error." if first_test and recovered_from_stall

        restricted_tests = nil
        if supported_only
          restricted_tests = t.methods.select {|x| server.supported_tests.include? x['id']}.map {|x| x['test_method']}
          test.tests_subset = restricted_tests
        end

        if t.resource_class?
          val = test.execute(t.resource_class.constantize).values.first
        else
          val = test.execute().values.first
        end

        crop_large_responses(val)

        # can't store results larger than approx 16MB due to limitation of mongodb.
        val_size = val.to_bson.size
        raise "Result size (#{val_size} bytes) exceeded maximum #{MAX_DOCUMENT_SIZE} byte size for Crucible." if val_size >= MAX_DOCUMENT_SIZE

      rescue Exception => e
        Rails.logger.error e.message
        Rails.logger.error e.backtrace

        val = t.methods.clone
        val.each do |m|
          m['status'] = 'error'
          m['message'] = e.message
        end
      end

      result.result = val

      # If somebody else picked up this job while I was working on this, don't save these results and leave
      return false if TestRun.find(self.id).worker_id != this_worker_id

      self.last_updated = DateTime.now
      self.test_results << result
      self.status = 'complete' if self.test_results.length == self.tests.length
      self.save

      first_test = false

      yield(result, i, self.tests.length) if block_given?
    end

    self.server.aggregate(self)
    compliance = server.get_compliance()
    summary = Summary.new({server_id: self.server.id, test_run: self, compliance: compliance, generated_at: Time.now})
    self.server.summary = summary
    self.server.percent_passing = (compliance['passed'].to_f / ([compliance['total'].to_f || 0, 1].max)) * 100.0
    self.server.last_run_at = Time.now
    summary.save!
    self.server.save!

    self.status = 'finished'
    self.save

    true

  end

  def serializable_hash(options = nil)
    hash = super(options)
    hash['id'] = hash.delete('_id').to_s if(hash.has_key?('_id'))
    hash
  end

  private

  def crop_large_responses(test_results)
    error_message = "Response not saved because this test result has exceeded Crucible\'s maximum size of #{MAX_DOCUMENT_SIZE} bytes."

    response_sizes = []
    test_results.each_with_index do |result, result_index|
      result[:requests].each_with_index do |request, request_index|
        response_sizes << [result_index, request_index, request["response"][:body].to_bson.size]
      end
    end

    response_sizes.sort{|a,b| b[2]<=>a[2]}.each do |item|
      if test_results.to_bson.size >= MAX_DOCUMENT_SIZE
        test_results[item[0]][:requests][item[1]]['response'][:body] = error_message
      end
    end
  end

end


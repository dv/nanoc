# encoding: utf-8

usage       'compile [options]'
summary     'compile items of this site'
description <<-EOS
Compile all items of the current site.

The compile command will show all items of the site as they are processed. The time spent compiling the item will be printed, as well as a status message, which can be one of the following:

CREATED - The compiled item did not yet exist and has been created

UPDATED - The compiled item did already exist and has been modified

IDENTICAL - The item was deemed outdated and has been recompiled, but the compiled version turned out to be identical to the already existing version

SKIP - The item was deemed not outdated and was therefore not recompiled

EOS

option :a, :all,   '(ignored)'
option :f, :force, '(ignored)'

module Nanoc::CLI::Commands

  class Compile < ::Nanoc::CLI::CommandRunner

    extend Nanoc::Memoization

    # Listens to compilation events and reacts to them. This abstract class
    # does not have a real implementation; subclasses should override {#start}
    # and set up notifications to listen to.
    #
    # @abstract Subclasses must override {#start} and may override {#stop}.
    class Listener

      # Starts the listener. Subclasses should override this method and set up listener notifications.
      #
      # @abstract
      def start
        raise NotImplementedError, "Subclasses of Listener should implement #start"
      end

      # Stops the listener. The default implementation removes self from all notification center observers.
      def stop
        Nanoc::NotificationCenter.remove_all(self)
      end

    end

    # Generates diffs for every output file written
    class DiffGenerator < Listener

      # @see Listener#start
      def start
        require 'tempfile'
        old_contents = {}
        Nanoc::NotificationCenter.on(:will_write_rep) do |rep, snapshot|
          path = rep.raw_path(:snapshot => snapshot)
          old_contents[rep] = File.file?(path) ? File.read(path) : nil
        end
        Nanoc::NotificationCenter.on(:rep_written) do |rep, path, is_created, is_modified|
          if !rep.binary?
            new_contents = File.file?(path) ? File.read(path) : nil
            if old_contents[rep] && new_contents
              generate_diff_for(rep, old_contents[rep], new_contents)
            end
          end
        end
      end

      # @see Listener#stop
      def stop
        super
        self.teardown_diffs
      end

    protected

      def setup_diffs
        @diff_lock    = Mutex.new
        @diff_threads = []
        FileUtils.rm('output.diff') if File.file?('output.diff')
      end

      def teardown_diffs
        @diff_threads.each { |t| t.join }
      end

      def generate_diff_for(rep, old_content, new_content)
        return if old_content == new_content

        @diff_threads << Thread.new do
          # Generate diff
          diff = diff_strings(old_content, new_content)
          diff.sub!(/^--- .*/,    '--- ' + rep.raw_path)
          diff.sub!(/^\+\+\+ .*/, '+++ ' + rep.raw_path)

          # Write diff
          @diff_lock.synchronize do
            File.open('output.diff', 'a') { |io| io.write(diff) }
          end
        end
      end

      def diff_strings(a, b)
        require 'open3'

        # Create files
        Tempfile.open('old') do |old_file|
          Tempfile.open('new') do |new_file|
            # Write files
            old_file.write(a)
            old_file.flush
            new_file.write(b)
            new_file.flush

            # Diff
            cmd = [ 'diff', '-u', old_file.path, new_file.path ]
            Open3.popen3(*cmd) do |stdin, stdout, stderr|
              result = stdout.read
              return (result == '' ? nil : result)
            end
          end
        end
      rescue Errno::ENOENT
        warn 'Failed to run `diff`, so no diff with the previously compiled ' \
             'content will be available.'
        nil
      end

    end

    # Records the time spent per filter and per item representation
    class TimingRecorder < Listener

      # @option params [Array<Nanoc::ItemRep>] :reps The list of item representations in the site
      def initialize(params={})
        @filter_times = {}

        @reps       = params.fetch(:reps)
      end

      # @see Listener#start
      def start
        Nanoc::NotificationCenter.on(:filtering_started) do |rep, filter_name|
          @filter_times[filter_name] ||= []
          @filter_times[filter_name] << Time.now
        end
        Nanoc::NotificationCenter.on(:filtering_ended) do |rep, filter_name|
          @filter_times[filter_name] << Time.now - @filter_times[filter_name].pop
        end
      end

      # @see Listener#stop
      def stop
        super
        self.print_profiling_feedback
      end

    protected

      def print_profiling_feedback
        # Get max filter length
        max_filter_name_length = @filter_times.keys.map { |k| k.to_s.size }.max
        return if max_filter_name_length.nil?

        # Print warning if necessary
        if @reps.any? { |r| !r.compiled? }
          $stderr.puts
          $stderr.puts "Warning: profiling information may not be accurate because " +
                       "some items were not compiled."
        end

        # Print header
        puts
        puts ' ' * max_filter_name_length + ' | count    min    avg    max     tot'
        puts '-' * max_filter_name_length + '-+-----------------------------------'

        @filter_times.to_a.sort_by { |r| r[1] }.each do |row|
          # Extract data
          filter_name, samples = *row

          # Calculate stats
          count = samples.size
          min   = samples.min
          tot   = samples.inject { |memo, i| memo + i}
          avg   = tot/count
          max   = samples.max

          # Format stats
          count = format('%4d',   count)
          min   = format('%4.2f', min)
          avg   = format('%4.2f', avg)
          max   = format('%4.2f', max)
          tot   = format('%5.2f', tot)

          # Output stats
          filter_name = format("%#{max_filter_name_length}s", filter_name)
          puts "#{filter_name} |  #{count}  #{min}s  #{avg}s  #{max}s  #{tot}s"
        end
      end

    end

    # Shows a progress bar if filtering a certain item rep takes longer than a certain threshold
    class FilterProgressPrinter < Listener

      # @see Listener#start
      def start
        Nanoc::NotificationCenter.on(:filtering_started) do |rep, filter_name|
          start_filter_progress(rep, filter_name)
        end
        Nanoc::NotificationCenter.on(:filtering_ended) do |rep, filter_name|
          stop_filter_progress(rep, filter_name)
        end
      end

    protected

      def start_filter_progress(rep, filter_name)
        # Only show progress on terminals
        return if !$stdout.tty?

        @progress_thread = Thread.new do
          delay = 1.0
          step  = 0

          text = "  running #{filter_name} filter… "

          loop do
            if Thread.current[:stopped]
              # Clear
              if delay < 0.1
                $stdout.print ' ' * (text.length + 3) + "\r"
              end

              break
            end

            # Show progress
            if delay < 0.1
              $stdout.print text + %w( | / - \\ )[step] + "\r"
              step = (step + 1) % 4
            end

            sleep 0.1
            delay -= 0.1
          end

        end
      end

      def stop_filter_progress(rep, filter_name)
        # Only show progress on terminals
        return if !$stdout.tty?

        @progress_thread[:stopped] = true
      end

    end

    # Controls garbage collection so that it only occurs once every 20 items
    class GCController < Listener

      def initialize
        @gc_count = 0
      end

      # @see Listener#start
      def start
        Nanoc::NotificationCenter.on(:compilation_started) do |rep|
          if @gc_count % 20 == 0 && !ENV.has_key?('TRAVIS')
            GC.enable
            GC.start
            GC.disable
          end
          @gc_count += 1
        end
      end

      # @see Listener#stop
      def stop
        super
        GC.enable
      end

    end

    # Prints debug information (compilation started/ended, filtering started/ended, …)
    class DebugPrinter < Listener

      # @see Listener#start
      def start
        Nanoc::NotificationCenter.on(:compilation_started) do |rep|
          puts "*** Started compilation of #{rep.inspect}"
        end
        Nanoc::NotificationCenter.on(:compilation_ended) do |rep|
          puts "*** Ended compilation of #{rep.inspect}"
          puts
        end
        Nanoc::NotificationCenter.on(:compilation_failed) do |rep, e|
          puts "*** Suspended compilation of #{rep.inspect}: #{e.message}"
        end
        Nanoc::NotificationCenter.on(:cached_content_used) do |rep|
          puts "*** Used cached compiled content for #{rep.inspect} instead of recompiling"
        end
        Nanoc::NotificationCenter.on(:filtering_started) do |rep, filter_name|
          puts "*** Started filtering #{rep.inspect} with #{filter_name}"
        end
        Nanoc::NotificationCenter.on(:filtering_ended) do |rep, filter_name|
          puts "*** Ended filtering #{rep.inspect} with #{filter_name}"
        end
        Nanoc::NotificationCenter.on(:visit_started) do |item|
          puts "*** Started visiting #{item.inspect}"
        end
        Nanoc::NotificationCenter.on(:visit_ended) do |item|
          puts "*** Ended visiting #{item.inspect}"
        end
        Nanoc::NotificationCenter.on(:dependency_created) do |src, dst|
          puts "*** Dependency created from #{src.inspect} onto #{dst.inspect}"
        end
      end

    end

    # Prints file actions (created, updated, deleted, identical, skipped)
    class FileActionPrinter < Listener

      # @option params [Array<Nanoc::ItemRep>] :reps The list of item representations in the site 
      def initialize(params={})
        @rep_times       = {}

        @reps            = params.fetch(:reps)
      end

      # @see Listener#start
      def start
        Nanoc::NotificationCenter.on(:compilation_started) do |rep|
          @rep_times[rep.raw_path] = Time.now
        end
        Nanoc::NotificationCenter.on(:compilation_ended) do |rep|
          @rep_times[rep.raw_path] = Time.now - @rep_times[rep.raw_path]
        end
        Nanoc::NotificationCenter.on(:rep_written) do |rep, path, is_created, is_modified|
          action = (is_created ? :create : (is_modified ? :update : :identical))
          level  = (is_created ? :high   : (is_modified ? :high   : :low))
          duration = Time.now - @rep_times[rep.raw_path] if @rep_times[rep.raw_path]
          Nanoc::CLI::Logger.instance.file(level, action, path, duration)
        end
      end

      # @see Listener#stop
      def stop
        super
        @reps.select { |r| !r.compiled? }.each do |rep|
          rep.raw_paths.each do |snapshot_name, filename|
            next if filename.nil?
            duration = @rep_times[filename]
            Nanoc::CLI::Logger.instance.file(:high, :skip, filename, duration)
          end
        end
      end

    end

    def run
      self.require_site
      self.check_for_deprecated_usage
      self.setup_listeners

      puts "Compiling site…"
      time_before = Time.now
      self.site.compile
      self.prune
      time_after = Time.now
      puts
      puts "Site compiled in #{format('%.2f', time_after - time_before)}s."
    end

  protected

    def prune  
      if self.site.config[:prune][:auto_prune]
        Nanoc::Extra::Pruner.new(self.site, :exclude => self.prune_config_exclude).run
      end
    end

    def setup_listeners
      @listeners = []

      if self.site.config[:enable_output_diff]
        @listeners << Nanoc::CLI::Commands::Compile::DiffGenerator.new
      end

      if self.debug?
        @listeners << Nanoc::CLI::Commands::Compile::DebugPrinter.new
      end

      if options.fetch(:verbose, false)
        @listeners << Nanoc::CLI::Commands::Compile::TimingRecorder.new(:reps => self.reps)
      end

      @listeners << Nanoc::CLI::Commands::Compile::FilterProgressPrinter.new
      @listeners << Nanoc::CLI::Commands::Compile::GCController.new
      @listeners << Nanoc::CLI::Commands::Compile::FileActionPrinter.new(:reps => self.reps)

      @listeners.each { |s| s.start }
    end

    def teardown_listeners
      @listeners.each { |s| s.stop }
    end

    def reps
      self.site.items.map { |i| i.reps }.flatten
    end
    memoize :reps

    def check_for_deprecated_usage
      # Check presence of --all option
      if options.has_key?(:all) || options.has_key?(:force)
        $stderr.puts "Warning: the --force option (and its deprecated --all alias) are, as of nanoc 3.2, no longer supported and have no effect."
      end

      # Warn if trying to compile a single item
      if arguments.size == 1
        $stderr.puts '-' * 80
        $stderr.puts 'Note: As of nanoc 3.2, it is no longer possible to compile a single item. When invoking the “compile” command, all items in the site will be compiled.'
        $stderr.puts '-' * 80
      end
    end

    def prune_config
      self.site.config[:prune] || {}
    end

    def prune_config_exclude
      self.prune_config[:exclude] || {}
    end

  end

end

runner Nanoc::CLI::Commands::Compile

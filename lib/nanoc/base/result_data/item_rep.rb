module Nanoc::Int
  # A single representation (rep) of an item ({Nanoc::Int::Item}). An item can
  # have multiple representations. A representation has its own output file.
  # A single item can therefore have multiple output files, each run through
  # a different set of filters with a different layout.
  #
  # @api private
  class ItemRep
    # Contains all private methods. Mixed into {Nanoc::Int::ItemRep}.
    #
    # @api private
    module Private
      # @return [Hash] A hash containing the assigns that will be used in the
      #   next filter or layout operation. The keys (symbols) will be made
      #   available during the next operation.
      attr_accessor :assigns

      # @return [Boolean] true if this representation has already been
      #   compiled during the current or last compilation session; false
      #   otherwise
      #
      # @api private
      attr_accessor :compiled
      alias_method :compiled?, :compiled

      # @return [Hash<Symbol,String>] A hash containing the raw paths (paths
      #   including the path to the output directory and the filename) for all
      #   snapshots. The keys correspond with the snapshot names, and the
      #   values with the path.
      #
      # @api private
      attr_accessor :raw_paths

      # @return [Hash<Symbol,String>] A hash containing the paths for all
      #   snapshots. The keys correspond with the snapshot names, and the
      #   values with the path.
      #
      # @api private
      attr_accessor :paths

      # @return [Hash<Symbol,String>] A hash containing the paths to the
      #   temporary _files_ that filters write binary content to. This is only
      #   used when the item representation is binary. The keys correspond
      #   with the snapshot names, and the values with the filename. When
      #   writing the item representation, the file corresponding with the
      #   requested snapshot (usually `:last`) will be copied from
      #   `filenames[snapshot]` to `raw_paths[snapshot]`.
      #
      # @api private
      attr_reader :temporary_filenames

      # @return [Hash<Symbol,String>] A hash containing the content at all
      #   snapshots. The keys correspond with the snapshot names, and the
      #   values with the content.
      #
      # @api private
      attr_accessor :content

      # Writes the item rep's compiled content to the rep's output file.
      #
      # This method will send two notifications: one before writing the item
      # representation, and one after. These notifications can be used for
      # generating diffs, for example.
      #
      # @api private
      #
      # @param [Symbol, nil] snapshot The name of the snapshot to write.
      #
      # @return [void]
      def write(snapshot = :last)
        ItemRepWriter.new.write(self, snapshot)
      end

      # Resets the compilation progress for this item representation. This is
      # necessary when an unmet dependency is detected during compilation.
      #
      # @api private
      #
      # @return [void]
      def forget_progress
        initialize_content
      end

      # Returns the type of this object. Will always return `:item_rep`,
      # because this is an item rep. For layouts, this method returns
      # `:layout`.
      #
      # @api private
      #
      # @return [Symbol] :item_rep
      def type
        :item_rep
      end
    end

    include Private

    # @return [Nanoc::Int::Item] The item to which this rep belongs
    attr_reader :item

    # @return [Symbol] The representation's unique name
    attr_reader :name

    # @return [Boolean] true if this rep is currently binary; false otherwise
    attr_reader :binary
    alias_method :binary?, :binary

    # @return [Array] A list of snapshots, represented as arrays where the
    #   first element is the snapshot name (a Symbol) and the last element is
    #   a Boolean indicating whether the snapshot is final or not
    attr_accessor :snapshots

    # Creates a new item representation for the given item.
    #
    # @param [Nanoc::Int::Item] item The item to which the new representation will
    #   belong.
    #
    # @param [Symbol] name The unique name for the new item representation.
    def initialize(item, name)
      # Set primary attributes
      @item   = item
      @name   = name

      # Set binary
      @binary = @item.binary?

      # Set default attributes
      @raw_paths  = {}
      @paths      = {}
      @assigns    = {}
      @snapshots  = []
      initialize_content

      # Reset flags
      @compiled = false
    end

    # Returns the compiled content from a given snapshot.
    #
    # @option params [String] :snapshot The name of the snapshot from which to
    #   fetch the compiled content. By default, the returned compiled content
    #   will be the content compiled right before the first layout call (if
    #   any).
    #
    # @return [String] The compiled content at the given snapshot (or the
    #   default snapshot if no snapshot is specified)
    def compiled_content(params = {})
      # Make sure we're not binary
      if item.binary?
        raise Nanoc::Int::Errors::CannotGetCompiledContentOfBinaryItem.new(self)
      end

      # Notify
      Nanoc::Int::NotificationCenter.post(:visit_started, item)
      Nanoc::Int::NotificationCenter.post(:visit_ended,   item)

      # Get name of last pre-layout snapshot
      snapshot_name = params.fetch(:snapshot) { @content[:pre] ? :pre : :last }
      is_moving = [:pre, :post, :last].include?(snapshot_name)

      # Check existance of snapshot
      snapshot = snapshots.find { |s| s.first == snapshot_name }
      if !is_moving && (snapshot.nil? || snapshot[-1] == false)
        raise Nanoc::Int::Errors::NoSuchSnapshot.new(self, snapshot_name)
      end

      # Verify snapshot is usable
      is_still_moving =
        case snapshot_name
        when :post, :last
          true
        when :pre
          snapshot.nil? || !snapshot[-1]
        end
      is_usable_snapshot = @content[snapshot_name] && (self.compiled? || !is_still_moving)
      unless is_usable_snapshot
        raise Nanoc::Int::Errors::UnmetDependency.new(self)
      end

      @content[snapshot_name]
    end

    # Checks whether content exists at a given snapshot.
    #
    # @return [Boolean] True if content exists for the snapshot with the
    #   given name, false otherwise
    #
    # @since 3.2.0
    def snapshot?(snapshot_name)
      !@content[snapshot_name].nil?
    end
    alias_method :has_snapshot?, :snapshot?

    # Returns the item rep’s raw path. It includes the path to the output
    # directory and the full filename.
    #
    # @option params [Symbol] :snapshot (:last) The snapshot for which the
    #   path should be returned
    #
    # @return [String] The item rep’s path
    def raw_path(params = {})
      Nanoc::Int::NotificationCenter.post(:visit_started, item)
      Nanoc::Int::NotificationCenter.post(:visit_ended,   item)

      snapshot_name = params[:snapshot] || :last
      @raw_paths[snapshot_name]
    end

    # Returns the item rep’s path, as used when being linked to. It starts
    # with a slash and it is relative to the output directory. It does not
    # include the path to the output directory. It will not include the
    # filename if the filename is an index filename.
    #
    # @option params [Symbol] :snapshot (:last) The snapshot for which the
    #   path should be returned
    #
    # @return [String] The item rep’s path
    def path(params = {})
      Nanoc::Int::NotificationCenter.post(:visit_started, item)
      Nanoc::Int::NotificationCenter.post(:visit_ended,   item)

      snapshot_name = params[:snapshot] || :last
      @paths[snapshot_name]
    end

    # Runs the item content through the given filter with the given arguments.
    # This method will replace the content of the `:last` snapshot with the
    # filtered content of the last snapshot.
    #
    # This method is supposed to be called only in a compilation rule block
    # (see {Nanoc::Int::CompilerDSL#compile}).
    #
    # @see Nanoc::Int::ItemRepProxy#filter
    #
    # @param [Symbol] filter_name The name of the filter to run the item
    #   representations' content through
    #
    # @param [Hash] filter_args The filter arguments that should be passed to
    #   the filter's #run method
    #
    # @return [void]
    def filter(filter_name, filter_args = {})
      # Get filter class
      klass = filter_named(filter_name)
      raise Nanoc::Int::Errors::UnknownFilter.new(filter_name) if klass.nil?

      # Check whether filter can be applied
      if klass.from_binary? && !self.binary?
        raise Nanoc::Int::Errors::CannotUseBinaryFilter.new(self, klass)
      elsif !klass.from_binary? && self.binary?
        raise Nanoc::Int::Errors::CannotUseTextualFilter.new(self, klass)
      end

      begin
        # Notify start
        Nanoc::Int::NotificationCenter.post(:filtering_started, self, filter_name)

        # Create filter
        filter = klass.new(assigns)

        # Run filter
        source = self.binary? ? temporary_filenames[:last] : @content[:last]
        result = filter.setup_and_run(source, filter_args)
        if klass.to_binary?
          temporary_filenames[:last] = filter.output_filename
        else
          @content[:last] = result
          @content[:last].freeze
        end
        @binary = klass.to_binary?

        # Check whether file was written
        if self.binary? && !File.file?(filter.output_filename)
          raise "The #{filter_name.inspect} filter did not write anything to the required output file, #{filter.output_filename}."
        end

        # Create snapshot
        snapshot(@content[:post] ? :post : :pre, final: false) unless self.binary?
      ensure
        # Notify end
        Nanoc::Int::NotificationCenter.post(:filtering_ended, self, filter_name)
      end
    end

    # Lays out the item using the given layout. This method will replace the
    # content of the `:last` snapshot with the laid out content of the last
    # snapshot.
    #
    # This method is supposed to be called only in a compilation rule block
    # (see {Nanoc::Int::CompilerDSL#compile}).
    #
    # @see Nanoc::Int::ItemRepProxy#layout
    #
    # @param [Nanoc::Int::Layout] layout The layout to use
    #
    # @param [Symbol] filter_name The name of the filter to layout the item
    #   representations' content with
    #
    # @param [Hash] filter_args The filter arguments that should be passed to
    #   the filter's #run method
    #
    # @return [void]
    def layout(layout, filter_name, filter_args)
      # Check whether item can be laid out
      raise Nanoc::Int::Errors::CannotLayoutBinaryItem.new(self) if self.binary?

      # Create "pre" snapshot
      if @content[:post].nil?
        snapshot(:pre, final: true)
      end

      # Create filter
      klass = filter_named(filter_name)
      raise Nanoc::Int::Errors::UnknownFilter.new(filter_name) if klass.nil?
      filter = klass.new(assigns.merge({ layout: layout }))

      # Visit
      Nanoc::Int::NotificationCenter.post(:visit_started, layout)
      Nanoc::Int::NotificationCenter.post(:visit_ended,   layout)

      begin
        # Notify start
        Nanoc::Int::NotificationCenter.post(:processing_started, layout)
        Nanoc::Int::NotificationCenter.post(:filtering_started,  self, filter_name)

        # Layout
        @content[:last] = filter.setup_and_run(layout.raw_content, filter_args)

        # Create "post" snapshot
        snapshot(:post, final: false)
      ensure
        # Notify end
        Nanoc::Int::NotificationCenter.post(:filtering_ended,  self, filter_name)
        Nanoc::Int::NotificationCenter.post(:processing_ended, layout)
      end
    end

    # Creates a snapshot of the current compiled item content.
    #
    # @param [Symbol] snapshot_name The name of the snapshot to create
    #
    # @option params [Boolean] :final (true) True if this is the final time
    #   the snapshot will be updated; false if it is a non-final moving
    #   snapshot (such as `:pre`, `:post` or `:last`)
    #
    # @return [void]
    def snapshot(snapshot_name, params = {})
      is_final = params.fetch(:final, true)

      unless self.binary?
        @content[snapshot_name] = @content[:last]
      end

      if snapshot_name == :pre && is_final
        snapshots << [:pre, true]
      end

      write(snapshot_name) if is_final
    end

    # Returns a recording proxy that is used for determining whether the
    # compilation has changed, and thus whether the item rep needs to be
    # recompiled.
    #
    # @api private
    #
    # @return [Nanoc::Int::ItemRepRecorderProxy] The recording proxy
    def to_recording_proxy
      Nanoc::Int::ItemRepRecorderProxy.new(self)
    end

    # Returns false because this item is not yet a proxy, and therefore does
    # need to be wrapped in a proxy during compilation.
    #
    # @api private
    #
    # @return [false]
    #
    # @see Nanoc::Int::ItemRepRecorderProxy#proxy?
    # @see Nanoc::Int::ItemRepProxy#proxy?
    def proxy?
      false
    end
    alias_method :is_proxy?, :proxy?

    # Returns an object that can be used for uniquely identifying objects.
    #
    # @api private
    #
    # @return [Object] An unique reference to this object
    def reference
      [type, item.identifier, name]
    end

    def inspect
      "<#{self.class} name=\"#{name}\" binary=#{self.binary?} raw_path=\"#{raw_path}\" item.identifier=\"#{item.identifier}\">"
    end

    private

    def initialize_content
      # Initialize content and filenames
      if self.binary?
        @temporary_filenames = { last: @item.raw_filename }
        @content             = {}
      else
        @content             = { last: @item.raw_content }
        @content[:last].freeze
        @temporary_filenames = {}
      end
    end

    def filter_named(name)
      Nanoc::Filter.named(name)
    end
  end
end

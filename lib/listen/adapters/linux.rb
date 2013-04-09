module Listen
  module Adapters

    # Listener implementation for Linux `inotify`.
    #
    class Linux < Adapter
      extend DependencyManager

      # Declare the adapter's dependencies
      dependency 'rb-inotify', '~> 0.9'

      # Watched inotify events
      #
      # @see http://www.tin.org/bin/man.cgi?section=7&topic=inotify
      # @see https://github.com/nex3/rb-inotify/blob/master/lib/rb-inotify/notifier.rb#L99-L177
      #
      EVENTS = [:recursive, :attrib, :create, :delete, :move, :close_write]

      # The message to show when the limit of inotify watchers is not enough
      #
      INOTIFY_LIMIT_MESSAGE = <<-EOS.gsub(/^\s*/, '')
        Listen error: unable to monitor directories for changes.

        Please head to https://github.com/guard/listen/wiki/Increasing-the-amount-of-inotify-watchers
        for information on how to solve this issue.
      EOS

      attr_accessor :worker, :worker_thread, :poll_thread

      # Initializes the Adapter.
      #
      # @see Listen::Adapter#initialize
      #
      def initialize(directories, options = {}, &callback)
        super
        @worker = init_worker
      rescue Errno::ENOSPC
        abort(INOTIFY_LIMIT_MESSAGE)
      end

      # Starts the adapter.
      #
      # @param [Boolean] blocking whether or not to block the current thread after starting
      #
      def start(blocking = true)
        super

        @worker_thread = Thread.new { worker.run }
        @poll_thread   = Thread.new { poll_changed_directories } if report_changes?

        worker_thread.join if blocking
      end

      # Stops the adapter.
      #
      def stop
        mutex.synchronize do
          return if stopped
          super
        end

        worker.stop
        Thread.kill(worker_thread) if worker_thread
        poll_thread.join if poll_thread
      end

      # Checks if the adapter is usable on Linux.
      #
      # @return [Boolean] whether usable or not
      #
      def self.usable?
        return false if RbConfig::CONFIG['target_os'] !~ /linux/i
        super
      end

    private

      # Initializes a INotify worker and adds a watcher for
      # each directory passed to the adapter.
      #
      # @return [INotify::Notifier] initialized worker
      #
      def init_worker
        callback = lambda do |event|
          if paused || (
            # Event on root directory
            event.name == ""
          ) || (
            # INotify reports changes to files inside directories as events
            # on the directories themselves too.
            #
            # @see http://linux.die.net/man/7/inotify
            event.flags.include?(:isdir) and (event.flags & [:close, :modify]).any?
          )
            # Skip all of these!
            next
          end

          mutex.synchronize do
            @changed_directories << File.dirname(event.absolute_name)
          end
        end

        INotify::Notifier.new.tap do |worker|
          directories.each { |dir| worker.watch(dir, *EVENTS, &callback) }
        end
      end

    end

  end
end

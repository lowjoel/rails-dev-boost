require 'monitor'

module RailsDevelopmentBoost
  module Async
    class Middleware
      def initialize(app)
        @app = app
      end
      
      def call(env)
        if DependenciesPatch.applied? && DependenciesPatch.async?
          Async.synchronize { @app.call(env) }
        else
          @app.call(env)
        end
      end
    end
    
    extend self
    autoload :Reactor, 'rails_development_boost/async/reactor'
    
    MONITOR = Monitor.new
    
    def heartbeat_check!
      if @reactor
        unless @reactor.alive_and_watching?(ActiveSupport::Dependencies.autoload_paths)
          @reactor.stop
          @reactor = nil
          start!
        end
        re_raise_unload_error_if_any
      else
        start!
      end
      @unloaded_something.tap { @unloaded_something = false }
    end
    
    def synchronize
      MONITOR.synchronize { yield }
    end
    
    def usable?
      Reactor.implementation
    end
    
    def process_new_async_value(new_value)
      if new_value
        if !Async.usable?
          msg = 'Unable to start rails-dev-boost in an asynchronous mode. '
          if gem_error = Reactor.gem_load_error
            msg << "Please install the missing gem for even faster rails-dev-boost experience:\n#{gem_error}\n" <<
                   "If you can't use the suggest gem version please let me know at https://github.com/thedarkone/rails-dev-boost/issues !\n"
          else
            msg << "Are you running on a OS that is 'async-unsupported' by rails-dev-boost? Please open an issue on github: https://github.com/thedarkone/rails-dev-boost/issues !"
          end
          msg << "\nTo get rid of this message disable the rails-dev-boost's async mode by putting the following code " +
                 "in a Rails initializer file (these are found in config/initializers directory):\n" +
                 "\n\tRailsDevelopmentBoost.async = false if defined?(RailsDevelopmentBoost)\n\n"
          async_warning(msg)
          new_value = false
        elsif in_console?
          async_warning('Warning: using asynchronous mode in Rails console mode might result in surprising behaviour and is not recommended.')
        end
      end
      new_value
    end
    
    def enable_by_default!(user_provided_value = false)
      unless user_provided_value
        DependenciesPatch.async = true unless usable? # trigger the warning message, unless there is a user supplied `async` setting
        DependenciesPatch.async = !in_console?
      end
    end
    
    private
    def in_console?
      defined?(Rails::Console)
    end
    
    def async_warning(msg)
      msg = msg.gsub(/^/, '[RAILS-DEV-BOOST] ')
      Kernel.warn(msg)
      Rails.logger.info(msg)
    end
    
    def start!
      if @reactor = Reactor.get
        @reactor.watch(ActiveSupport::Dependencies.autoload_paths) {|changed_dirs| unload_affected(changed_dirs)}
        @reactor.start!
        self.unloaded_something = LoadedFile.unload_modified! # don't miss-out on any of the file changes as the async thread hasn't been started as of yet
      end
    end
    
    def re_raise_unload_error_if_any
      if e = @unload_error
        @unload_error = nil
        raise e, e.message, e.backtrace
      end
    end
    
    def unload_affected(changed_dirs)
      changed_dirs = changed_dirs.map {|changed_dir| File.expand_path(changed_dir).chomp(File::SEPARATOR)}
      
      synchronize do
        self.unloaded_something = LoadedFile::LOADED.unload_modified!(changed_dirs)
      end
    rescue Exception => e
      @unload_error ||= e
    end
    
    def unloaded_something=(value)
      @unloaded_something ||= value
    end
  end
end

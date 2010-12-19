require 'erb'
require 'rubygems/dependency_installer'

module Bundler
  class Installer < Environment
    def self.install(root, definition, options = {})
      installer = new(root, definition)
      installer.run(options)
      installer
    end

    def run(options)
      if Bundler.settings[:frozen]
        @definition.ensure_equivalent_gemfile_and_lockfile
      end

      if dependencies.empty?
        Bundler.ui.warn "The Gemfile specifies no dependencies"
        return
      end

      if Bundler.default_lockfile.exist? && !options["update"]
        begin
          tmpdef = Definition.build(Bundler.default_gemfile, Bundler.default_lockfile, nil)
          local = true unless tmpdef.new_platform? || tmpdef.missing_specs.any?
        rescue BundlerError
        end
      end

      # Since we are installing, we can resolve the definition
      # using remote specs
      unless local
        options["local"] ?
          @definition.resolve_with_cache! :
          @definition.resolve_remotely!
      end

      # Ensure that BUNDLE_PATH exists
      Bundler.mkdir_p(Bundler.bundle_path) unless File.exist?(Bundler.bundle_path)

      # Must install gems in the order that the resolver provides
      # as dependencies might actually affect the installation of
      # the gem.
      specs.each do |spec|
        install_spec(spec)
      end

      lock
    end

    def install_spec(spec)
      if installed_on_rvm? spec
        copy_gem spec
      else
        install_spec_from_source spec
      end
    end

    def gem_sources
      Dir["#{ENV['rvm_path']}/gems/#{rvm_ruby_string}*/gems/*"]
    end

    def rvm_ruby_string
      str = ENV['rvm_ruby_string']
      str.empty? ? `ruby -v`.split[0..1].join('-').sub(/(p\d+)$/, '-\1') : str
    end

    def installed_gem_map
      installed = {}
      gem_sources.each do |source|
        installed[File.basename(source)] = source
      end
      installed
    end

    def installed_gems
      installed_gem_map.keys
    end

    def installed_on_rvm?(spec)
      installed_gems.map { |dir| File.basename(dir) }.include? gem_name_and_version(spec)
    end

    def gem_name_and_version(spec)
      "#{spec.name}-#{spec.version}"
    end

    def copy_gem(spec)
      puts "Copying!"
      require 'fileutils'

      current_gemset = `rvm gemset name`.strip
      gemset_dir = "#{ENV['rvm_path']}/gems/#{rvm_ruby_string}#{"@#{current_gemset}" unless current_gemset.empty?}"
      gem_dir = File.join(gemset_dir, 'gems')
      gemspec_dir = File.join(gemset_dir, 'specifications')
      [gem_dir, gemspec_dir].each do |dir|
        unless File.exist? dir
          print "Make directory #{dir}? "
          if $stdin.gets.strip =~ /^y/
            FileUtils.mkdir_p dir
          else
            puts "Exiting!"
            exit 0
          end
        end
      end
      begin
        #TODO: Copt gemspecs too
        FileUtils.cp_r installed_gem_map[gem_name_and_version(spec)], gem_dir
      rescue ArgumentError
      end
    end

    def install_spec_from_source(spec)
      puts "install from source..."
      spec.source.fetch(spec) if spec.source.respond_to?(:fetch)

      # unless requested_specs.include?(spec)
      #   Bundler.ui.debug "  * Not in requested group; skipping."
      #   next
      # end

      begin
        old_args = Gem::Command.build_args
        Gem::Command.build_args = [Bundler.settings["build.#{spec.name}"]]
        spec.source.install(spec)
        Bundler.ui.debug "from #{spec.loaded_from} "
      ensure
        Gem::Command.build_args = old_args
      end

      Bundler.ui.info ""
      generate_bundler_executable_stubs(spec) if Bundler.settings[:bin]
      FileUtils.rm_rf(Bundler.tmp)
    end


  private

    def generate_bundler_executable_stubs(spec)
      bin_path = Bundler.bin_path
      template = File.read(File.expand_path('../templates/Executable', __FILE__))
      relative_gemfile_path = Bundler.default_gemfile.relative_path_from(bin_path)
      ruby_command = Thor::Util.ruby_command

      spec.executables.each do |executable|
        next if executable == "bundle"
        File.open "#{bin_path}/#{executable}", 'w', 0755 do |f|
          f.puts ERB.new(template, nil, '-').result(binding)
        end
      end
    end
  end
end

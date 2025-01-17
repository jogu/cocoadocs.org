#!/usr/bin/env ruby

require 'cocoapods-downloader'
require 'cocoapods-core'
require 'cocoapods'

require 'jazzy'

gem 'nap'
require 'rest'

require 'ostruct'
require 'yaml'
require 'json'
require "fileutils"
require "octokit"
require 'open-uri'
require 'net/http'
require "shellwords"
require "colored"

require 'tilt'
require "slim"
require "nokogiri"
require 'tempfile'
require 'mustache'

class CocoaDocs < Object

  def help
    puts "\n" +
    "    CocoaDocs command line                                                    \n" +
    "                                                                              \n" +
    "     ./cocoadocs.rb preview [spec name or podspec path] [branch]              \n" +
    "     ./cocoadocs.rb cocoadocs doc [spec name or path]                         \n" +
    "     ./cocoadocs.rb cocoadocs days [days]                                     \n" +
    "     ./cocoadocs.rb cocoadocs url [json podspec url]                          \n" +
    "                                                                              \n" +
    "     Options:                                                                 \n" +
    "                                                                              \n" +
    "       --verbose                                                              \n" +
    "       --skip-fetch-specs                                                     \n" +
    "       --skip-cloc                                                            \n" +
    "       --skip-source-download                                                 \n" +
    "       --dont-delete-source                                                   \n" +
    "       --create-website \"http://example.com/\"                               \n" +
    "       --specs-repo \"name/repo\" or \"http://u:p@server.com/git/specs.git\"  \n" +
    "       --data-folder \"activity\"                                             \n" +
    "       --upload-s3 \"bucketname\"                                             \n" +
    "       --master                                                               \n"
  end

  $specs_repo = "CocoaPods/Specs"
  $s3_bucket = "cocoadocs.org"
  $website_home = "http://cocoadocs.org/"
  $cocoadocs_specs_name = "cocoadocs_specs"

  $verbose = false
  $log_all_terminal_commands = false

  # Download and document
  $fetch_specs = true
  $skip_source_download = false
  $force_branch = nil
  $overwrite_existing_source_files = true
  $delete_source_after_docset_creation = true
  $skip_downloading_readme = false
  $skip_cloc = false

  # Generate site site & json
  $generate_website = false
  $generate_docset_json = false
  $generate_apple_json = false

  # Upload html / docsets
  $upload_docsets_to_s3 = false
  $upload_redirects_for_docsets = false
  $upload_stats = false

  $upload_site_to_s3 = false

  # Constrain all downloads and data into one subfolder
  $active_folder_name = "activity"
  $current_dir = File.dirname(File.expand_path(__FILE__))
  $active_folder = File.join($current_dir, $active_folder_name)

  # Include all the classes files
  Dir[File.join($current_dir, "classes/*.rb")].each do |file|
    require_relative(file)
  end

  # command line parsing

  def initialize(args)

    appledoc_version = `vendor/appledoc --version`.strip.gsub("appledoc version: ", "").split(" ")[0].to_f
    if appledoc_version < 2.2
      puts "You need an updated version of appledoc, grab the latest release: https://github.com/tomaz/appledoc/releases".red
      exit
    end

    cloc_path = `which cloc`.strip.chomp
    if cloc_path == ""
      puts "You need an to install cloc".red
      puts "run " + "brew install cloc".red
      exit
    end

    if ARGV.length > 0
      setup_options ARGV

      command = ARGV[0].gsub(/-/, '_').to_sym rescue :help
      @params = ARGV[1..-1]
      commands.include?(command.to_sym) ? send(command.to_sym) : help
    else
      help
    end
  end

  #    parse all docs and upload to s3
  #    ruby cocoadocs.rb all
  def all
    setup_for_cocoadocs
    update_specs_repo
    source = Pod::Source.new(File.join($active_folder, $cocoadocs_specs_name))

    source.all_specs.each do |spec|
      document_spec(spec)
    end
  end

  #    parse the latest version of every pod and upload to s3
  #    ruby cocoadocs.rb all_latest
  def all_latest
    setup_for_cocoadocs
    update_specs_repo
    source = Pod::Source.new(File.join($active_folder, $cocoadocs_specs_name))

    source.pod_sets.each do |set|
      document_spec_with_name set.name
    end
  end

  #    just parse ARAnalytics and put the docset in the activity folder
  #    cocoadocs doc "ARAnalytics"

  def doc
    update_specs_repo

    @params.each do |param|
      next if param.start_with?('--')

      name = param
      if name.end_with? ".podspec.json"
        document_spec_at_path(name)
      else
        document_spec_with_name(name)
      end
    end
  end


  def cocoadocs
    case @params.shift
    when 'doc', 'docs'
      cocoadocs_doc
    when 'day', 'days'
      cocoadocs_day
    when 'url'
      cocoadocs_url
    end
  end

  def setup_for_cocoadocs
    $generate_website = true
    $generate_docset_json = true
    $generate_apple_json = true
    $website_home = "http://cocoadocs.org/"

    $upload_docsets_to_s3 = true
    $upload_redirects_for_spec_index = true
    $upload_site_to_s3 = true
    $s3_bucket = "cocoadocs.org"
    $upload_stats = true
  end

  def cocoadocs_day
    setup_for_cocoadocs
    update_specs_repo

    updated_specs = specs_for_days_ago_diff @params.first
    vputs "Looking at #{updated_specs.lines.count}"

    updated_specs.lines.each_with_index do |spec_filepath, index|
      spec_filepath.gsub! /\n/, ''
      spec_path = $active_folder + "/" + $cocoadocs_specs_name + "/" + spec_filepath.strip
      p spec_path
      next unless spec_filepath.end_with? ".podspec.json" and File.exists? spec_path

      document_spec_at_path spec_path
    end
  end

  def cocoadocs_doc
    setup_for_cocoadocs
    doc
  end

  def cocoadocs_url
    $fetch_specs = false
    setup_for_cocoadocs

    url = @params.first
    spec_name = url.split("/")[-1]
    podspec_path = $active_folder + "/podspecs/" + spec_name

    FileUtils.mkdir_p(File.dirname(podspec_path))

    open(url) do|f|
      File.open(podspec_path, 'w') { |tmp| tmp.write(f.read) }
      @params = [podspec_path]
      doc
    end
  end

  def spec_with_name(name)
    source = Pod::Source.new(File.join($active_folder, $cocoadocs_specs_name))
    set = source.search(Pod::Dependency.new(name))

    if set
      set.specification.root
    end
  end

  # tip: offline command
  # bundle exec ./cocoadocs.rb preview ARAnalytics mybranch --verbose --skip-fetch --skip-readme-download --skip-source-download

  def preview

    name = ARGV[1]
    branch = ARGV[2] || "master"
    if branch.start_with? "--"
      branch = "master"
    end

    update_specs_repo

    spec_path = $active_folder + "/#{$cocoadocs_specs_name}/Specs/"
    version = ""

    if Dir.exists? spec_path  + name
      version = Dir.entries(spec_path + name).last
      spec_path = File.join("#{spec_path}","#{name}", "#{version}", "#{name}.podspec.json")

      $overwrite_existing_source_files = true
      $delete_source_after_docset_creation = false
      $force_branch = branch


      document_spec_at_path spec_path
      command  "open \"#{ $active_folder }/docsets/#{ name }/#{ version }/\""
      puts "Preview: \"#{ $active_folder }/docsets/#{ name }/#{ version }/\""
    else
      puts "Could not find spec at " + spec_path + name
    end

  end

  private

  def setup_options options

    if options.find_index("--beta") != nil
      $beta = true
    end

    if options.find_index("--master") != nil
      $force_branch = "master"
    end

    if options.find_index("--verbose") != nil
      $verbose = true
      $log_all_terminal_commands = true
    end

    if options.find_index("--skip-fetch-specs") != nil
      $fetch_specs = false
    end

    if options.find_index("--skip-fetch") != nil
      $skip_cloc = true
    end

    if options.find_index("--dont-delete-source") != nil
      $delete_source_after_docset_creation = false
    end

    index = options.find_index "--create-website"
    if index != nil
      $generate_website = true
      $generate_docset_json = true
      $generate_apple_json = true
      $website_home = options[index + 1]
    end

    index = options.find_index("--upload-s3")
    if index != nil
      $upload_docsets_to_s3 = true
      $upload_redirects_for_spec_index = true
      $upload_redirects_for_docsets = true
      $s3_bucket = options[index + 1]
    end

    index = options.find_index("--skip-source-download")
    if index != nil
      $skip_source_download = true
    end

    index = options.find_index("--skip-readme-download")
    if index != nil
      $skip_downloading_readme = true
    end

    index = options.find_index "--specs-repo"
    $specs_repo = options[index + 1] if index != nil

    index = options.find_index "--data-folder"
    $active_folder_name = options[index + 1] if index != nil

    $active_folder = File.join($current_dir, $active_folder_name)
  end

  # Update or clone Cocoapods/Specs
  def update_specs_repo
    repo = File.join($active_folder, $cocoadocs_specs_name)
    unless File.exists? repo
      vputs "Creating Specs Repo for #{$specs_repo}"
      unless repo.include? "://"
        command "git clone git://github.com/#{$specs_repo}.git \"#{repo}\" --depth 1"
      else
        command "git clone \"#{$specs_repo}\" \"#{repo}\" --depth 1"
      end
    else
      if $fetch_specs
        vputs "Updating Specs Repo"
        run_git_command_in_specs "stash"
        run_git_command_in_specs "pull origin master"
      end
    end
  end


  # returns an array from the diff log for the last x days
  def specs_for_days_ago_diff days_ago
    sha = run_git_command_in_specs 'rev-list -n1 --before="' + days_ago + ' day ago" master'
    diff_log = run_git_command_in_specs "diff --name-status #{sha}"
    cleanup_git_logs diff_log
  end

  # cleans up and removes modification notice to the diff
  def cleanup_git_logs diff_log
    diff_log.lines.map do |line|

      line.slice!(0).strip!
      line.gsub! /\t/, ''

    end.join
  end

  # We have to run commands from a different git root if we want to do anything in the Specs repo
  def run_git_command_in_specs git_command
    Dir.chdir(File.join($active_folder, $cocoadocs_specs_name)) do
      vputs "git #{git_command}"
     `git #{git_command}`
    end
  end

  # generate the documentation for the pod
  def document_spec(spec)
    state = "failed"

    begin
      download_location = $active_folder + "/download/#{spec.name}/#{spec.version}/#{spec.name}"
      docset_location   = $active_folder + "/docsets/#{spec.name}/#{spec.version}/"
      readme_location   = $active_folder + "/readme/#{spec.name}/#{spec.version}/index.html"
      pod_root_location = $active_folder + "/docsets/#{spec.name}/"
      templates_location = $active_folder + "/template/#{spec.name}/"
      api_json_location = $active_folder + "/docsets/#{spec.name}/#{spec.version}/stats.json"

      unless $skip_source_download
        downloader = SourceDownloader.new ({ :spec => spec, :download_location => download_location, :overwrite => $overwrite_existing_source_files })
        FileUtils.rm_r download_location if File.directory?(download_location)
        downloader.download_pod_source_files
      end

      settings = CocoaDocsSettings.settings_at_location download_location
      readme = ReadmeGenerator.new ({ :spec => spec, :readme_location => readme_location })
      readme.create_readme

      cloc = ClocStatsGenerator.new(:spec => spec, :source_download_location => download_location)
      cloc_results = cloc.generate

      version_metadata = SpecMetadataGenerator.new(:spec => spec, :docset_path => docset_location)
      versions = version_metadata.generate

      fixer = DocsetFixer.new({ :docset_path => docset_location, :readme_path => readme_location, :pod_root => pod_root_location, :spec => spec, :versions => versions })

      documented = false

      swift = cloc_results.find { |r| r[:language] == 'Swift' }
      header = cloc_results.find { |r| r[:language] == 'C/C++ Header' }

      if swift && (!header || swift[:files] > header[:files])
        vputs "Using jazzy to document Swift pod"
        download_spec_path = download_location + "/#{spec.name}.podspec.json"
        File.open(download_spec_path, 'w') { |f| f.write spec.to_json }
        config = Jazzy::Config.new.tap do |c|
          c.podspec = Pathname(download_spec_path)
          c.output = Pathname(docset_location)
          c.min_acl = Jazzy::SourceDeclaration::AccessControlLevel.public
          c.docset_icon = Pathname(__FILE__).parent + 'resources/docset_icon.png'
          c.docset_path = "com.cocoadocs.#{spec.name.downcase}.#{spec.name}.docset"
          c.readme_path = Pathname(readme_location)
          c.source_directory = Pathname(download_location)
          c.clean = true
          c.dash_url = "#{$website_home}docsets/#{spec.name}/#{spec.name}.xml"
        end

        begin
          source_module = Jazzy::DocBuilder.build(Jazzy::Config.instance = config)

          percent_doc = source_module.doc_coverage
          fixer.readme_path = docset_location + '/index.html'
          fixer.fix_for_jazzy

          documented = true
        rescue => e
          vputs "Jazzy failed: #{e.message.red}\n#{e.backtrace.inspect.red}"
        end
      end

      unless documented
        appledoc_template = AppledocTemplateGenerator.new({ :spec => spec, :appledoc_templates_path => templates_location, :source_download_location => download_location, :versions => versions, :library_settings => settings })
        appledoc_template.generate

        generator = DocsetGenerator.new({ :spec => spec, :to => docset_location, :from => download_location, :readme_location => readme_location, :appledoc_templates_path => templates_location, :source_download_location => download_location, :library_settings => settings })
        generator.create_docset

        fixer.fix
      end

      version_metadata.save

      fixer.add_index_redirect_to_latest_to_pod
      fixer.add_docset_redirects if $upload_redirects_for_docsets
      percent_doc ||= fixer.get_doc_percent

      cloc = ClocStatsGenerator.new(:spec => spec, :source_download_location => download_location)
      cloc_results = cloc.generate
      vputs cloc_results.to_s

      tester = TestingIdealist.new(:spec => spec, :download_location => download_location)
      testing_estimate = tester.testimate

      stats = StatsGenerator.new(:spec => spec, :api_json_path => api_json_location, :cloc_results => cloc_results, :readme_location => readme_location, :download_location => download_location, :doc_percent => percent_doc, :testing_estimate => testing_estimate, :docset_location => docset_location)
      stats.upload if $upload_stats

      SocialImageGenerator.new(:spec => spec, :output_folder => docset_location, :stats_generator => stats).generate

      $generator = WebsiteGenerator.new(:generate_json => $generate_docset_json, :spec => spec)
      $generator.upload_docset if $upload_docsets_to_s3

      if $delete_source_after_docset_creation
        vputs "Deleting source files"
        command "rm -rf \"#{download_location}\""
        command "rm -rf \"#{docset_location}\"" if $upload_site_to_s3
      end

      state = "success"

    rescue Exception => e
      if spec != nil
        error_path = "errors/#{spec.name}/#{spec.version}/error.json"
        FileUtils.mkdir_p(File.dirname(error_path))
        FileUtils.rm(error_path) if File.exists? error_path

        open(error_path, 'a'){ |f|
          report = { "message" => e.message , "trace" => e.backtrace }
          f.puts report.to_json.to_s
        }
      end

      open('error_log.txt', 'a') { |f|
        f.puts "\n\n\n --------------#{spec.defined_in_file}-------------"
        f.puts e.message
        f.puts "------"
        f.puts e.backtrace.inspect
      }

      puts "--------------#{spec.defined_in_file}-------------".red
      puts e.message.red
      puts "------"
      puts e.backtrace.inspect.red
    end

    HistoryLogger.new(:spec => spec, :download_location => docset_location, :source_download_location => download_location).append_state state

    puts "* - " + $website_home + "docsets/" + spec.name + "/" + spec.version.to_s  + "/"
  end

  def document_spec_at_path(spec_path)
    spec = Pod::Specification.from_file(spec_path)
    document_spec(spec)
  end

  def document_spec_with_name(name)
    spec = spec_with_name(name)

    if spec
      document_spec(spec)
    else
      puts "Could not find #{name}"
    end
  end

  def commands
    (public_methods - Object.public_methods).map(&:to_sym)
  end

end

CocoaDocs.new(ARGV)

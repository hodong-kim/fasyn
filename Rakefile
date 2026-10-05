# frozen_string_literal: true

require "fileutils"
require "open3"
require "rake"
require "shellwords"
require "socket"
require "tmpdir"
require "thread"
require "timeout"

ROOT = File.expand_path(__dir__)
BUILD_ROOT = File.join(ROOT, "build")
FASYN_TMP_ROOT = File.join(BUILD_ROOT, "tmp")
FileUtils.mkdir_p FASYN_TMP_ROOT
ENV["TMPDIR"] = FASYN_TMP_ROOT

def fail_config(message)
  abort "ERROR: #{message}"
end

def env_choice(primary, alias_name = nil, default = nil)
  primary_value = ENV[primary]
  alias_value = alias_name ? ENV[alias_name] : nil

  if primary_value && alias_value && primary_value != alias_value
    fail_config "#{primary} and #{alias_name} disagree"
  end

  primary_value || alias_value || default
end

CLAIR_SOURCE_ROOT = File.expand_path(
  ENV["FASYN_CLAIR_ROOT"] ||
    ENV["CLAIR_ALIRE_PREFIX"] ||
    File.join(ROOT, "..", "clair")
)
CLAIR_PREPARED_ROOT = ENV["FASYN_CLAIR_PREPARED_ROOT"]
CLAIR_BUILD_ROOT = File.expand_path(
  CLAIR_PREPARED_ROOT || File.join(BUILD_ROOT, "deps", "clair")
)
CLAIR_PREPARED = !CLAIR_PREPARED_ROOT.nil?
CLAIR_BUILD_PROFILE =
  env_choice("CLAIR_BUILD_PROFILE", "PROFILE", "release")
CLAIR_SECURITY_INSTRUMENTATION =
  env_choice("CLAIR_SECURITY_INSTRUMENTATION", nil, "none")
CLAIR_ARTIFACT_PROFILE =
  if CLAIR_SECURITY_INSTRUMENTATION == "none"
    CLAIR_BUILD_PROFILE
  else
    "#{CLAIR_BUILD_PROFILE}-security-#{CLAIR_SECURITY_INSTRUMENTATION}"
  end
CLAIR_LIBRARY_TYPE =
  env_choice("CLAIR_LIBRARY_TYPE", nil, "static-pic")
FASYN_ARTIFACT_PROFILE =
  "#{CLAIR_ARTIFACT_PROFILE}-clair-#{CLAIR_LIBRARY_TYPE}".freeze

SUPPORTED_TARGET_OSES = %w[freebsd linux darwin windows android].freeze
SUPPORTED_BUILD_PROFILES = %w[debug release].freeze
SUPPORTED_SECURITY_INSTRUMENTATIONS = %w[none asan-ubsan].freeze
SUPPORTED_LIBRARY_TYPES = %w[static static-pic relocatable].freeze

fail_config "unsupported build profile: #{CLAIR_BUILD_PROFILE}" unless
  SUPPORTED_BUILD_PROFILES.include?(CLAIR_BUILD_PROFILE)
fail_config(
  "unsupported security instrumentation: #{CLAIR_SECURITY_INSTRUMENTATION}"
) unless
  SUPPORTED_SECURITY_INSTRUMENTATIONS.include?(CLAIR_SECURITY_INSTRUMENTATION)
fail_config "unsupported Clair library type: #{CLAIR_LIBRARY_TYPE}" unless
  SUPPORTED_LIBRARY_TYPES.include?(CLAIR_LIBRARY_TYPE)

def capture!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  abort "command failed: #{command.join(' ')}\n#{stderr}" unless status.success?
  stdout.strip
end

def infer_target_os(target)
  value = target.downcase
  return "android" if value.include?("android")
  return "freebsd" if value.include?("freebsd")
  return "linux" if value.include?("linux")
  return "darwin" if value.include?("darwin") || value.include?("apple")
  return "windows" if value.include?("mingw") ||
                      value.include?("windows") ||
                      value.include?("win32")

  nil
end

def clair_target
  @clair_target ||=
    env_choice("CLAIR_TARGET", "TARGET") ||
    capture!("clang", "-dumpmachine")
end

def clair_host_target
  @clair_host_target ||= ENV["CLAIR_HOST_TARGET"] ||
                         capture!("clang", "-dumpmachine")
end

def clair_target_os
  return @clair_target_os if defined?(@clair_target_os)

  inferred = infer_target_os(clair_target)
  explicit = ENV["CLAIR_TARGET_OS"]
  if explicit && inferred && explicit != inferred
    fail_config(
      "CLAIR_TARGET_OS=#{explicit} conflicts with CLAIR_TARGET=#{clair_target}"
    )
  end

  selected = explicit || inferred
  message = "cannot infer Clair target OS from #{clair_target.inspect}; "
  message += "set CLAIR_TARGET_OS"
  fail_config message unless selected
  fail_config "unsupported Clair target OS: #{selected}" unless
    SUPPORTED_TARGET_OSES.include?(selected)

  @clair_target_os = selected
end

def clair_gpr_target
  return @clair_gpr_target if defined?(@clair_gpr_target)

  selected = env_choice(
    "CLAIR_GPR_TARGET",
    "GPR_TARGET",
    clair_target == clair_host_target ? nil : clair_target
  )
  @clair_gpr_target = selected
end

def native_target?
  selected_gpr_target = clair_gpr_target
  clair_target == clair_host_target &&
    (selected_gpr_target.nil? || selected_gpr_target == clair_target)
end

def validate_build_context!
  clair_target_os
  clair_gpr_target

  return if CLAIR_SECURITY_INSTRUMENTATION == "none"

  fail_config "security instrumentation requires a native target" unless
    native_target?
  fail_config(
    "security instrumentation is not accepted on #{clair_target_os}"
  ) unless
    %w[linux freebsd darwin].include?(clair_target_os)
end

def ensure_native_execution!
  return if native_target?

  if clair_target == clair_host_target &&
     clair_gpr_target && clair_gpr_target != clair_target
    message = "cannot run tests with GPR target #{clair_gpr_target} while "
    message += "CLAIR_TARGET=#{clair_target}; use rake test-build"
    abort message
  end

  message = "cannot run #{clair_target} tests on host #{clair_host_target}; "
  message += "use rake test-build and execute binaries on the target"
  abort message
end

def find_program(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
    path = File.join(directory, name)
    return path if File.file?(path) && File.executable?(path)
  end
  nil
end

def alire_toolchain_version(path, prefix)
  name = File.basename(File.dirname(File.dirname(path)))
  match = name.match(/\A#{Regexp.escape(prefix)}_([0-9]+(?:\.[0-9]+)*)_/)
  match ? match[1].split(".").map(&:to_i) : [0]
end

def gprbuild_command
  @gprbuild_command ||= begin
    if ENV["GPRBUILD"]
      words = Shellwords.split(ENV["GPRBUILD"])
      fail_config "GPRBUILD must not be empty" if words.empty?
      return @gprbuild_command = words
    end
    selected = find_program("gprbuild")
    if selected.nil? && infer_target_os(clair_host_target) == "darwin"
      roots = [File.join(Dir.home, ".local", "share")]
      roots.unshift(ENV["XDG_DATA_HOME"]) unless
        ENV["XDG_DATA_HOME"].to_s.empty?
      candidates = roots.uniq.flat_map do |root|
        Dir.glob(File.join(root, "alire", "toolchains", "gprbuild_*",
                           "bin", "gprbuild"))
      end
      executable = candidates.select do |path|
        File.file?(path) && File.executable?(path)
      end
      selected = executable.max_by do |path|
        alire_toolchain_version(path, "gprbuild")
      end
    end
    [selected || "gprbuild"]
  end
end

def native_darwin?
  native_target? && clair_target_os == "darwin"
end

def darwin_toolchain_environment
  return {} unless native_darwin?

  @darwin_toolchain_environment ||= begin
    command = gprbuild_command.first
    program = command.include?(File::SEPARATOR) ? command : find_program(command)
    fail_config "GPRbuild not found; install it or set GPRBUILD" unless program
    directory = File.dirname(File.realpath(program))
    gprconfig = File.join(directory, "gprconfig")
    gprconfig = find_program("gprconfig") unless File.executable?(gprconfig)
    fail_config "gprconfig not found for the selected GPRbuild" unless gprconfig
    resolved = false
    Dir.mktmpdir("fasyn-gprconfig-", FASYN_TMP_ROOT) do |temporary|
      config = File.join(temporary, "host.cgpr")
      _stdout, _stderr, status = Open3.capture3(
        gprconfig, "--batch", "--config=Ada", "-o", config
      )
      resolved = status.success? && File.file?(config) &&
                 File.read(config).match?(/for Driver\s*\(\s*"Ada"\s*\)/)
    end

    environment = {}
    unless resolved
      # Alire installs GNAT separately from GPRbuild. Keep the fallback local
      # to build subprocesses and select only a compiler for this host.
      root = File.dirname(File.dirname(directory))
      candidates = Dir.glob(File.join(root, "gnat_native_*", "bin", "gcc"))
      arch = ->(triple) { triple.split("-").first.sub(/\Aarm64\z/, "aarch64") }
      compatible = candidates.select do |path|
        next false unless File.file?(path) && File.executable?(path)

        stdout, _stderr, status = Open3.capture3(path, "-dumpmachine")
        status.success? && infer_target_os(stdout.strip) == "darwin" &&
          arch.call(stdout.strip) == arch.call(clair_host_target)
      end
      compiler = compatible.max_by do |path|
        alire_toolchain_version(path, "gnat_native")
      end
      fail_config "GNAT not found; add a compatible Ada toolchain to PATH" unless
        compiler
      environment["PATH"] =
        [File.dirname(compiler), ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR)
    end
    environment
  end
end

def build_environment
  environment = { "GPRBUILD" => Shellwords.join(gprbuild_command) }
  return environment unless native_darwin?

  environment.merge(darwin_toolchain_environment).merge(
    "MACOSX_DEPLOYMENT_TARGET" => macos_deployment_target
  )
end

def macos_deployment_target
  @macos_deployment_target ||= begin
    target = env_choice("CLAIR_MACOS_DEPLOYMENT_TARGET",
                        "MACOSX_DEPLOYMENT_TARGET") ||
             capture!("/usr/bin/sw_vers", "-productVersion")
    fail_config "invalid macOS deployment target: #{target.inspect}" unless
      /\A[0-9]+\.[0-9]+(?:\.[0-9]+)?\z/.match?(target)
    target
  end
end

def clair_darwin_prefixes
  return {} unless native_darwin?

  @clair_darwin_prefixes ||= begin
    # Clair owns dependency discovery. Reuse its public resolved context for
    # both the producer and imported GPR projects, including prepared roots.
    stdout, stderr, status = Open3.capture3(
      clair_environment.merge(build_environment), "rake", "--silent", "info",
      chdir: CLAIR_SOURCE_ROOT
    )
    fail_config "cannot resolve Clair build context:\n#{stderr}" unless
      status.success?
    context = stdout.lines.filter_map do |line|
      key, separator, value = line.strip.partition("=")
      [key, value] unless separator.empty?
    end.to_h
    %w[CLAIR_LIBYAML_PREFIX CLAIR_PCRE2_PREFIX CLAIR_GETTEXT_PREFIX].to_h do |key|
      value = context[key]
      fail_config "Clair build context is missing #{key}" if
        value.nil? || value.empty?
      [key, value]
    end
  end
end

def clair_gpr_switches
  [
    "-aP#{CLAIR_SOURCE_ROOT}",
    "-XCLAIR_BUILD_ROOT=#{CLAIR_BUILD_ROOT}",
    "-XCLAIR_TARGET=#{clair_target}",
    "-XCLAIR_TARGET_OS=#{clair_target_os}",
    "-XCLAIR_BUILD_PROFILE=#{CLAIR_BUILD_PROFILE}",
    "-XCLAIR_ARTIFACT_PROFILE=#{CLAIR_ARTIFACT_PROFILE}",
    "-XCLAIR_LIBRARY_TYPE=#{CLAIR_LIBRARY_TYPE}",
    "-XCLAIR_CORE_EXTERNALLY_BUILT=True"
  ] + clair_darwin_prefixes.map { |key, value| "-X#{key}=#{value}" }
end

def build_fasyn_project!(project, *arguments)
  switches = fasyn_gprbuild_switches + arguments + ["-P", project]
  if native_darwin?
    deployment = "-mmacosx-version-min=#{macos_deployment_target}"
    switches += ["-cargs:Ada", deployment, "-cargs:C", deployment,
                 "-largs", deployment]
  end
  run! build_environment, *gprbuild_command, *switches
end

def fasyn_gprbuild_switches
  validate_build_context!
  switches = ["-p", "-s"]
  switches << "--target=#{clair_gpr_target}" if clair_gpr_target
  switches + clair_gpr_switches
end

def fasyn_build_path(kind)
  File.join(ROOT, "build", kind, clair_target, FASYN_ARTIFACT_PROFILE)
end

def fasyn_test_generated_dir
  File.join(fasyn_build_path("gen"), "tests")
end

def fasyn_test_bin_dir
  File.join(fasyn_build_path("bin"), "tests")
end

def fasyn_test_executable(name)
  File.join(fasyn_test_bin_dir, name)
end

def fasyn_target_artifact_dirs
  %w[obj lib bin gen].map do |kind|
    File.join(ROOT, "build", kind, clair_target, FASYN_ARTIFACT_PROFILE)
  end
end

def run!(*command, chdir: ROOT)
  ok = system(*command, chdir: chdir)
  abort "command failed: #{command.join(' ')}" unless ok
end

def ensure_clair_source!
  abort "Clair source checkout not found: #{CLAIR_SOURCE_ROOT}" unless
    File.file?(File.join(CLAIR_SOURCE_ROOT, "clair.gpr")) &&
    File.file?(File.join(CLAIR_SOURCE_ROOT, "Rakefile"))
end

def path_contains?(parent, child)
  child == parent || child.start_with?(parent + File::SEPARATOR)
end

def ensure_prepared_clair_root!
  fail_config "prepared Clair build root not found: #{CLAIR_BUILD_ROOT}" unless
    File.directory?(CLAIR_BUILD_ROOT)

  source_root = File.realpath(CLAIR_SOURCE_ROOT)
  prepared_root = File.realpath(CLAIR_BUILD_ROOT)
  if path_contains?(source_root, prepared_root) ||
     path_contains?(prepared_root, source_root)
    message =
      "prepared Clair root must be independent of the Clair source checkout: "
    fail_config message + CLAIR_BUILD_ROOT
  end
end

def clair_environment
  environment = {
    "CLAIR_BUILD_ROOT" => CLAIR_BUILD_ROOT,
    "CLAIR_TARGET" => clair_target,
    "CLAIR_TARGET_OS" => clair_target_os,
    "CLAIR_BUILD_PROFILE" => CLAIR_BUILD_PROFILE,
    "CLAIR_SECURITY_INSTRUMENTATION" => CLAIR_SECURITY_INSTRUMENTATION,
    "CLAIR_LIBRARY_TYPE" => CLAIR_LIBRARY_TYPE
  }
  environment["CLAIR_GPR_TARGET"] = clair_gpr_target if clair_gpr_target
  environment
end

def prepare_clair!
  validate_build_context!
  ensure_clair_source!

  if CLAIR_PREPARED
    ensure_prepared_clair_root!
    return
  end

  legacy_checkout = File.join(CLAIR_BUILD_ROOT, ".git")
  if File.directory?(legacy_checkout)
    message = "legacy Clair source snapshot found at #{CLAIR_BUILD_ROOT}; "
    message += "remove it before using the artifact-only build root"
    abort message
  end

  FileUtils.mkdir_p File.dirname(CLAIR_BUILD_ROOT)
  run! clair_environment.merge(build_environment).merge(clair_darwin_prefixes),
       "rake", "build", chdir: CLAIR_SOURCE_ROOT
end

def prepare_clair_host_tools!
  validate_build_context!
  ensure_clair_source!

  if CLAIR_PREPARED
    clair_test_registry_generator
    return
  end

  FileUtils.mkdir_p File.dirname(CLAIR_BUILD_ROOT)
  run! clair_environment.merge(build_environment).merge(clair_darwin_prefixes),
       "rake", "host-tools", chdir: CLAIR_SOURCE_ROOT
end

def prepare_clair_tests!
  prepare_clair!
  prepare_clair_host_tools!
end

def clair_test_registry_generator
  base = File.join(
    CLAIR_BUILD_ROOT,
    "host",
    clair_host_target,
    "tools",
    "gen-clair-test-registry"
  )
  candidates = [base, "#{base}.exe"].select do |path|
    File.file?(path) && File.executable?(path)
  end

  abort "Clair test registry generator not found: #{base}" if candidates.empty?
  abort(
    "multiple Clair test registry generators found: #{candidates.join(', ')}"
  ) if candidates.length > 1
  candidates.first
end

def generate_test_registry!
  output_dir = fasyn_test_generated_dir
  FileUtils.mkdir_p output_dir
  run! clair_test_registry_generator,
       "--tests-dir", File.join(ROOT, "tests"),
       "--output-dir", output_dir,
       "--package", "Tests",
       "--registry-package", "Tests.Generated_Registry"
end

def build_fasyn_tests!
  generate_test_registry!
  build_fasyn_project! "fasyn_tests.gpr"
end

def run_fasyn_tests!
  ensure_native_execution!
  build_fasyn_tests!
  fixture = fasyn_test_executable("fasyn_classic_fixture")
  run!({ "FASYN_CLASSIC_FIXTURE" => fixture },
       fasyn_test_executable("fasyn_unit_tests"))
end

def run_fasyn_exchange_callback_memory!
  ensure_native_execution!

  unless %w[linux freebsd].include?(clair_target_os)
    puts "Fasyn Exchange callback memory regression: SKIP (#{clair_target_os})"
    return
  end

  build_fasyn_tests!
  script = File.join(ROOT, "tests", "fasyn_exchange_callback_churn.rb")
  executable =
    fasyn_test_executable("fasyn_exchange_callback_churn_fixture")
  run! "ruby", script, executable
end

def run_fasyn_execution_lifecycle_memory!
  ensure_native_execution!
  build_fasyn_tests!
  run! fasyn_test_executable("fasyn_execution_lifecycle_tests")
end

def fasyn_integer_env!(name, default, minimum: 0)
  value = Integer(ENV.fetch(name, default.to_s), 10)
  abort "#{name} must be at least #{minimum}" if value < minimum
  value
rescue ArgumentError
  abort "#{name} must be an integer"
end

def run_fasyn_soak!
  ensure_native_execution!
  iterations = fasyn_integer_env!("FASYN_SOAK_ITERATIONS", 25, minimum: 2)
  warmup = fasyn_integer_env!("FASYN_SOAK_WARMUP", 2, minimum: 1)
  abort "FASYN_SOAK_WARMUP cannot exceed FASYN_SOAK_ITERATIONS" if warmup > iterations

  timeout_seconds = fasyn_integer_env!(
    "FASYN_SOAK_TIMEOUT", iterations * 10 + 60, minimum: 1
  )
  progress_timeout = fasyn_integer_env!(
    "FASYN_SOAK_PROGRESS_TIMEOUT", 30, minimum: 1
  )
  max_rss_growth = fasyn_integer_env!(
    "FASYN_SOAK_MAX_RSS_GROWTH_KB", 4096, minimum: 0
  )
  max_fd_growth = fasyn_integer_env!(
    "FASYN_SOAK_MAX_FD_GROWTH", 0, minimum: 0
  )

  build_fasyn_tests!
  fixture = fasyn_test_executable("fasyn_classic_fixture")
  executable = fasyn_test_executable("fasyn_unit_tests")
  environment = {
    "FASYN_CLASSIC_FIXTURE" => fixture,
    "FASYN_TEST_REPEAT" => iterations.to_s
  }
  metrics = []
  metric_pattern =
    /\A\[SOAK\] iteration=(\d+)\/(\d+) rss_kb=(-?\d+) fds=(-?\d+)\z/
  exit_status = nil

  Open3.popen2e(environment, executable, "--quiet", chdir: ROOT) do |stdin, output, wait_thread|
    stdin.close
    queue = Queue.new
    reader = Thread.new do
      begin
        output.each_line { |line| queue << [:line, line] }
      rescue IOError
        raise unless output.closed?
      ensure
        queue << [:eof, nil]
      end
    end

    terminate_child = lambda do
      begin
        Process.kill("TERM", wait_thread.pid)
      rescue Errno::ESRCH
        nil
      end
      next if wait_thread.join(2)

      begin
        Process.kill("KILL", wait_thread.pid)
      rescue Errno::ESRCH
        nil
      end
      wait_thread.join(2)
    end

    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    last_progress = start_time
    finished_output = false

    until finished_output
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reason =
        if now - start_time > timeout_seconds
          "overall timeout after #{timeout_seconds}s"
        elsif now - last_progress > progress_timeout
          "no completed soak iteration for #{progress_timeout}s"
        end

      if reason
        terminate_child.call
        reader.join(2)
        abort "Fasyn soak validation failed: #{reason}"
      end

      if queue.empty?
        sleep 0.05
        next
      end
      kind, value = queue.pop

      if kind == :eof
        finished_output = true
        next
      end

      $stdout.print value
      match = metric_pattern.match(value.strip)
      next unless match

      iteration = Integer(match[1], 10)
      total = Integer(match[2], 10)
      rss_kb = Integer(match[3], 10)
      fds = Integer(match[4], 10)
      metrics << [iteration, total, rss_kb, fds]
      last_progress = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    reader.join
    exit_status = wait_thread.value
  rescue Interrupt
    terminate_child.call
    reader.join(2)
    raise
  end

  abort "Fasyn soak test process failed" unless exit_status&.success?
  abort "Fasyn soak produced #{metrics.length} metrics for #{iterations} iterations" unless
    metrics.length == iterations

  metrics.each_with_index do |metric, index|
    expected = index + 1
    iteration, total, rss_kb, fds = metric
    abort "Fasyn soak iteration sequence is inconsistent" unless
      iteration == expected && total == iterations
    abort "Fasyn soak RSS measurement is unavailable" if rss_kb < 0
    abort "Fasyn soak FD measurement is unavailable" if fds < 0
  end

  baseline = metrics[warmup - 1]
  steady = metrics[(warmup - 1)..]
  baseline_rss = baseline[2]
  baseline_fds = baseline[3]
  peak_rss = steady.map { |metric| metric[2] }.max
  peak_fds = steady.map { |metric| metric[3] }.max
  rss_growth = peak_rss - baseline_rss
  fd_growth = peak_fds - baseline_fds

  abort "Fasyn soak RSS growth #{rss_growth} KiB exceeds #{max_rss_growth} KiB" if
    rss_growth > max_rss_growth
  abort "Fasyn soak FD growth #{fd_growth} exceeds #{max_fd_growth}" if
    fd_growth > max_fd_growth

  puts "Fasyn soak: PASS"
  puts "  iterations       : #{iterations}"
  puts "  warmup baseline  : iteration #{warmup}"
  puts "  RSS baseline/peak: #{baseline_rss}/#{peak_rss} KiB"
  puts "  FD baseline/peak : #{baseline_fds}/#{peak_fds}"
end

def alr_executable
  ENV.fetch("FASYN_ALR", "alr")
end

def ensure_alr!
  capture! alr_executable, "--version"
rescue Errno::ENOENT
  abort "Alire executable not found: #{alr_executable}"
end

def alire_toolchain_inventory
  @alire_toolchain_inventory ||=
    capture!(alr_executable, "--no-color", "toolchain")
end

def alire_external_gnat16_version
  return @alire_external_gnat16_version if
    defined?(@alire_external_gnat16_version)

  versions = alire_toolchain_inventory.lines.filter_map do |line|
    match = line.match(/\Agnat_external\s+([0-9]+(?:[.][0-9]+)+)\s+/)
    next unless match

    version = match[1]
    version if version.split(".").first == "16"
  end

  if versions.empty?
    abort(
      "Alire did not detect an external GNAT 16 toolchain; " \
      "install or expose GNAT 16 before running Alire acceptance"
    )
  end

  @alire_external_gnat16_version =
    versions.max_by { |version| version.split(".").map(&:to_i) }
end

def alire_system_gprbuild_version
  return @alire_system_gprbuild_version if
    defined?(@alire_system_gprbuild_version)

  versions = alire_toolchain_inventory.lines.filter_map do |line|
    next unless line.include?("Provided by system package:")

    match = line.match(/\Agprbuild\s+([0-9]+(?:[.][0-9]+)+)\s+/)
    match && match[1]
  end

  if versions.empty?
    abort(
      "Alire did not detect a system-package gprbuild; " \
      "install a gprbuild compatible with GNAT 16 before Alire acceptance"
    )
  end

  @alire_system_gprbuild_version =
    versions.max_by { |version| version.split(".").map(&:to_i) }
end

def select_alire_toolchain!(workspace)
  gnat_version = alire_external_gnat16_version
  gprbuild_version = alire_system_gprbuild_version
  run! alr_executable, "config", "--set",
       "toolchain.external.gnat", %("TRUE"), chdir: workspace
  run! alr_executable, "config", "--set",
       "toolchain.use.gnat", %("gnat_external=#{gnat_version}"),
       chdir: workspace
  run! alr_executable, "config", "--set",
       "toolchain.use.gprbuild", %("gprbuild=#{gprbuild_version}"),
       chdir: workspace

  stdout, stderr, status = Open3.capture3(
    alr_executable, "exec", "--", "gnat", "--version", chdir: workspace
  )
  selected =
    stdout.lines.any? { |line| line.strip == "GNAT #{gnat_version}" }
  unless status.success? && selected
    abort(
      "Alire workspace did not select GNAT #{gnat_version}:\n" \
      "#{stdout}#{stderr}"
    )
  end

  _stdout, stderr, status = Open3.capture3(
    alr_executable, "exec", "--", "gprbuild", "--version", chdir: workspace
  )
  abort "Alire workspace did not select system gprbuild:\n#{stderr}" unless
    status.success?
end

def copy_alire_probe_tree!(destination)
  FileUtils.mkdir_p destination
  Dir.children(ROOT).sort.each do |entry|
    next if %w[.git alire build].include?(entry)

    FileUtils.cp_r(
      File.join(ROOT, entry),
      File.join(destination, entry),
      preserve: true
    )
  end
end

def copy_clair_probe_tree!(destination)
  FileUtils.mkdir_p destination
  Dir.children(CLAIR_SOURCE_ROOT).sort.each do |entry|
    next if %w[.git alire build].include?(entry)
    next if %w[.config.rb mkmf.log].include?(entry)

    FileUtils.cp_r(
      File.join(CLAIR_SOURCE_ROOT, entry),
      File.join(destination, entry),
      preserve: true
    )
  end
end

def write_alire_consumer!(root)
  FileUtils.mkdir_p File.join(root, "src")
  File.write(File.join(root, "alire.toml"), <<~TOML)
    name = "fasyn_consumer"
    description = "Temporary Fasyn Alire consumer"
    version = "0.0.0"
    licenses = "0BSD"
    project-files = ["fasyn_consumer.gpr"]
  TOML
  File.write(File.join(root, "fasyn_consumer.gpr"), <<~GPR)
    with "fasyn_runtime";
    project Fasyn_Consumer is
       for Source_Dirs use ("src");
       for Object_Dir use "obj";
       for Exec_Dir use "bin";
       for Main use ("main.adb");

       package Compiler is
          for Default_Switches ("Ada") use ("-gnat2022");
       end Compiler;
    end Fasyn_Consumer;
  GPR
  File.write(File.join(root, "src", "main.adb"), <<~ADA)
    with Fasyn.Listener;

    procedure Main is
       Context : Fasyn.Listener.Context;
    begin
       if Fasyn.Listener.Is_Active (Context) then
          raise Program_Error;
       end if;
    end Main;
  ADA
end

desc "Show the resolved Fasyn development context"
task :info do
  validate_build_context!
  puts "fasyn_root=#{ROOT}"
  puts "clair_source_root=#{CLAIR_SOURCE_ROOT}"
  puts "clair_build_root=#{CLAIR_BUILD_ROOT}"
  puts "clair_prepared=#{CLAIR_PREPARED}"
  puts "clair_host_target=#{clair_host_target}"
  puts "clair_target=#{clair_target}"
  puts "clair_target_os=#{clair_target_os}"
  puts "clair_gpr_target=#{clair_gpr_target}" if clair_gpr_target
  puts "clair_build_profile=#{CLAIR_BUILD_PROFILE}"
  puts "clair_artifact_profile=#{CLAIR_ARTIFACT_PROFILE}"
  puts "fasyn_artifact_profile=#{FASYN_ARTIFACT_PROFILE}"
  puts "clair_security_instrumentation=#{CLAIR_SECURITY_INSTRUMENTATION}"
  puts "clair_library_type=#{CLAIR_LIBRARY_TYPE}"
end

desc "Build the Fasyn core library and compile Clair-backed runtime sources"
task :build do
  prepare_clair!
  build_fasyn_project! "fasyn.gpr"
  build_fasyn_project! "fasyn_runtime.gpr", "-c", "-r"
end

task default: :build

desc "Build unit tests without running target programs"
task :"test-build" do
  prepare_clair_tests!
  build_fasyn_tests!
end

desc "Build and run the native unit suite once through Clair.Test"
task :"test-fast" do
  ensure_native_execution!
  prepare_clair_tests!
  run_fasyn_tests!
end

desc "Run canonical native tests including resource-stability regressions"
task :test do
  ensure_native_execution!
  prepare_clair_tests!
  run_fasyn_tests!
  run_fasyn_soak!
  run_fasyn_execution_lifecycle_memory!
  run_fasyn_exchange_callback_memory!
end

desc "Check executor lifecycle RSS stability through Clair.Test"
task :"test-execution-lifecycle-memory" do
  ensure_native_execution!
  prepare_clair_tests!
  run_fasyn_execution_lifecycle_memory!
end

desc "Check direct Exchange callback RSS/VSZ/thread/FD stability"
task :"test-exchange-callback-memory" do
  ensure_native_execution!
  prepare_clair_tests!
  run_fasyn_exchange_callback_memory!
end

desc "Repeat the full native attack-shaped suite in one process and check RSS/FD stability"
task :"test-soak" do
  ensure_native_execution!
  prepare_clair_tests!
  run_fasyn_soak!
end

desc "Run the native suite under Valgrind Memcheck"
task :"test-valgrind" do
  ensure_native_execution!
  prepare_clair_tests!
  build_fasyn_tests!

  valgrind = ENV.fetch("FASYN_VALGRIND", "valgrind")
  fixture = fasyn_test_executable("fasyn_classic_fixture")
  executable = fasyn_test_executable("fasyn_unit_tests")
  run!({ "FASYN_CLASSIC_FIXTURE" => fixture },
       valgrind,
       "--tool=memcheck",
       "--leak-check=full",
       "--show-leak-kinds=definite,indirect",
       "--errors-for-leak-kinds=definite,indirect",
       "--track-origins=yes",
       "--error-exitcode=99",
       executable)
end

desc "Validate Alire root and external consumer integration"
task :"test-alire" do
  ensure_clair_source!
  ensure_alr!

  Dir.mktmpdir("fasyn-alire-", FASYN_TMP_ROOT) do |dir|
    clair = File.join(dir, "clair")
    copy_clair_probe_tree! clair

    crate = File.join(dir, "fasyn")
    copy_alire_probe_tree! crate
    select_alire_toolchain! crate

    run! alr_executable, "-n", "with", "clair",
         "--use=#{clair}", chdir: crate
    run! alr_executable, "build", chdir: crate
    run! alr_executable, "exec", "--", "rake", "test", chdir: crate

    FileUtils.rm_rf File.join(crate, "build")
    FileUtils.rm_rf File.join(crate, "alire")

    consumer = File.join(dir, "consumer")
    write_alire_consumer! consumer
    select_alire_toolchain! consumer
    run! alr_executable, "-n", "with", "fasyn",
         "--use=#{crate}", chdir: consumer
    run! alr_executable, "build", chdir: consumer

    executable = File.join(consumer, "bin", "main")
    abort "Alire consumer executable not found: #{executable}" unless
      File.executable?(executable)
    run! executable, chdir: consumer
  end
end

namespace :alire do
  desc "Validate catalog Clair resolution before Fasyn publication"
  task :catalog_preflight do
    ensure_alr!

    stdout, stderr, status = Open3.capture3(alr_executable, "show", "clair")
    unless status.success?
      abort "Clair is not resolvable from the Alire index:\n#{stdout}#{stderr}"
    end

    Dir.mktmpdir("fasyn-alire-catalog-", FASYN_TMP_ROOT) do |dir|
      crate = File.join(dir, "fasyn")
      copy_alire_probe_tree! crate
      select_alire_toolchain! crate
      run! alr_executable, "build", chdir: crate

      FileUtils.rm_rf File.join(crate, "build")
      FileUtils.rm_rf File.join(crate, "alire")

      consumer = File.join(dir, "consumer")
      write_alire_consumer! consumer
      select_alire_toolchain! consumer
      run! alr_executable, "-n", "with", "fasyn",
           "--use=#{crate}", chdir: consumer
      run! alr_executable, "build", chdir: consumer

      executable = File.join(consumer, "bin", "main")
      abort "Alire catalog consumer executable not found: #{executable}" unless
        File.executable?(executable)
      run! executable, chdir: consumer
    end
  end
end

def nginx_executable!
  candidates = [
    ENV["FASYN_NGINX"],
    "/usr/local/sbin/nginx",
    "/usr/sbin/nginx"
  ].compact
  executable = candidates.find { |path| File.file?(path) && File.executable?(path) }
  abort "NGINX executable not found; set FASYN_NGINX" unless executable
  executable
end

def wait_for_tcp!(host, port, timeout: 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    begin
      socket = TCPSocket.new(host, port)
      socket.close
      return
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      abort "NGINX did not become ready" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
  end
end

def wait_for_pid(pid, timeout: 5)
  Timeout.timeout(timeout) { Process.wait2(pid).last }
rescue Timeout::Error
  nil
rescue Errno::ECHILD
  nil
end

def terminate_pid(pid)
  return unless pid

  Process.kill("TERM", pid)
  status = wait_for_pid(pid)
  return if status

  Process.kill("KILL", pid)
  Process.wait(pid)
rescue Errno::ESRCH, Errno::ECHILD
  nil
end

def read_if_exists(path)
  File.exist?(path) ? File.read(path) : ""
end

namespace :interop do
  desc "Run NGINX HTTP-to-FastCGI interoperability acceptance"
  task :nginx do
    ensure_native_execution!
    prepare_clair_tests!
    run_fasyn_tests!
    nginx = nginx_executable!
    fixture = fasyn_test_executable("fasyn_nginx_fixture")
    abort "NGINX fixture not found: #{fixture}" unless File.executable?(fixture)

    Dir.mktmpdir("fasyn-nginx-", FASYN_TMP_ROOT) do |dir|
      socket_path = File.join(dir, "fastcgi.sock")
      listener = UNIXServer.new(socket_path)
      port_socket = TCPServer.new("127.0.0.1", 0)
      port = port_socket.addr[1]
      port_socket.close

      FileUtils.mkdir_p File.join(dir, "client_body")
      FileUtils.mkdir_p File.join(dir, "fastcgi_temp")
      FileUtils.mkdir_p File.join(dir, "proxy_temp")
      FileUtils.mkdir_p File.join(dir, "scgi_temp")
      FileUtils.mkdir_p File.join(dir, "uwsgi_temp")
      config = File.join(dir, "nginx.conf")
      File.write(config, <<~NGINX)
        error_log #{dir}/error.log notice;
        pid #{dir}/nginx.pid;
        events { worker_connections 32; }
        http {
          access_log #{dir}/access.log;
          client_body_temp_path #{dir}/client_body;
          fastcgi_temp_path #{dir}/fastcgi_temp;
          proxy_temp_path #{dir}/proxy_temp;
          scgi_temp_path #{dir}/scgi_temp;
          uwsgi_temp_path #{dir}/uwsgi_temp;
          server {
            listen 127.0.0.1:#{port};
            location = /fasyn {
              fastcgi_pass unix:#{socket_path};
              fastcgi_connect_timeout 2s;
              fastcgi_send_timeout 10s;
              fastcgi_read_timeout 10s;
              fastcgi_keep_conn off;
              fastcgi_param REQUEST_METHOD $request_method;
              fastcgi_param QUERY_STRING $query_string;
              fastcgi_param CONTENT_TYPE $content_type;
              fastcgi_param CONTENT_LENGTH $content_length;
              fastcgi_param SCRIPT_NAME $uri;
            }
          }
        }
      NGINX

      fixture_log = File.open(File.join(dir, "fixture.log"), "w")
      nginx_log = File.open(File.join(dir, "nginx.log"), "w")
      fixture_pid = nil
      nginx_pid = nil

      begin
        fixture_pid = Process.spawn(
          { "FCGI_WEB_SERVER_ADDRS" => nil },
          fixture, in: listener, out: fixture_log, err: fixture_log
        )
        listener.close
        fixture_log.close

        nginx_pid = Process.spawn(
          nginx, "-p", "#{dir}/", "-c", config,
          "-g", "daemon off; master_process off;",
          out: nginx_log, err: nginx_log
        )
        nginx_log.close

        wait_for_tcp!("127.0.0.1", port)
        if (early = Process.wait2(fixture_pid, Process::WNOHANG))
          fixture_pid = nil
          abort "Fasyn NGINX fixture exited early: #{early.last.exitstatus}"
        end
        if (early = Process.wait2(nginx_pid, Process::WNOHANG))
          nginx_pid = nil
          abort "NGINX exited early: #{early.last.exitstatus}"
        end

        curl_candidates = [
          ENV["FASYN_CURL"],
          "/usr/local/bin/curl",
          "/usr/bin/curl"
        ].compact
        curl = curl_candidates.find do |path|
          File.file?(path) && File.executable?(path)
        end
        abort "curl executable not found; set FASYN_CURL" unless curl
        response, curl_error, curl_status = Open3.capture3(
          curl, "--silent", "--show-error", "--include", "--http1.1",
          "--connect-timeout", "2", "--max-time", "10",
          "--header", "Content-Type: text/plain",
          "--data-binary", "fasyn-nginx-body",
          "http://127.0.0.1:#{port}/fasyn?probe=nginx"
        )
        header, separator, body = response.partition("\r\n\r\n")
        unless curl_status.success? && separator == "\r\n\r\n" &&
               header.start_with?("HTTP/1.1 200") &&
               body == "fasyn-nginx-ok\n"
          nginx_details = read_if_exists(File.join(dir, "nginx.log"))
          error_details = read_if_exists(File.join(dir, "error.log"))
          fixture_details = read_if_exists(File.join(dir, "fixture.log"))
          access_details = read_if_exists(File.join(dir, "access.log"))
          abort [
            "NGINX interoperability failed:",
            "response=#{response.inspect}",
            "curl=#{curl_error}",
            "nginx=#{nginx_details}",
            "error=#{error_details}",
            "access=#{access_details}",
            "fixture=#{fixture_details}"
          ].join("\n")
        end

        fixture_status = wait_for_pid(fixture_pid)
        fixture_pid = nil if fixture_status
        abort "Fasyn NGINX fixture did not exit cleanly" unless
          fixture_status&.success?

        version_out, version_err, version_status = Open3.capture3(nginx, "-v")
        abort "cannot read NGINX version" unless version_status.success?
        version = (version_out + version_err).strip.sub("nginx version: ", "")
        puts "NGINX interoperability: PASS (#{version})"
      ensure
        listener.close unless listener.closed?
        fixture_log.close unless fixture_log.closed?
        nginx_log.close unless nginx_log.closed?
        terminate_pid(nginx_pid)
        terminate_pid(fixture_pid)
      end
    end
  end
end

desc "Remove Fasyn build products for the selected target/profile"
task :clean do
  FileUtils.rm_rf fasyn_target_artifact_dirs
end

desc "Remove all Fasyn-owned build products"
task :"clean-all" do
  %w[obj lib bin gen tmp].each do |kind|
    FileUtils.rm_rf File.join(BUILD_ROOT, kind)
  end

  unless CLAIR_PREPARED
    FileUtils.rm_rf File.join(BUILD_ROOT, "deps", "clair")
  end
end

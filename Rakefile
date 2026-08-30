# frozen_string_literal: true

require "fileutils"
require "open3"
require "rake"
require "socket"
require "tmpdir"
require "timeout"

ROOT = File.expand_path(__dir__)
CLAIR_ROOT = File.expand_path(
  ENV.fetch("FASYN_CLAIR_ROOT", File.join(ROOT, "..", "clair"))
)

CLAIR_BUILD_PROFILE = ENV.fetch("CLAIR_BUILD_PROFILE", ENV.fetch("PROFILE", "release"))

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
  return "windows" if value.include?("mingw") || value.include?("windows") || value.include?("win32")

  nil
end

def clair_target
  @clair_target ||= ENV["CLAIR_TARGET"] || ENV["TARGET"] || capture!("clang", "-dumpmachine")
end

def clair_host_target
  @clair_host_target ||= ENV["CLAIR_HOST_TARGET"] || capture!("clang", "-dumpmachine")
end

def clair_target_os
  @clair_target_os ||= ENV["CLAIR_TARGET_OS"] || infer_target_os(clair_target) ||
    abort("cannot infer Clair target OS from #{clair_target.inspect}")
end

def clair_gpr_switches(include_tests: false)
  switches = [
    "-aP#{CLAIR_ROOT}",
    "-XCLAIR_TARGET=#{clair_target}",
    "-XCLAIR_TARGET_OS=#{clair_target_os}",
    "-XCLAIR_BUILD_PROFILE=#{CLAIR_BUILD_PROFILE}"
  ]
  switches.insert(1, "-aP#{File.join(CLAIR_ROOT, 'tests')}") if include_tests
  switches
end

def run!(*command, chdir: ROOT)
  ok = system(*command, chdir: chdir)
  abort "command failed: #{command.join(' ')}" unless ok
end

def ensure_clair_checkout!
  abort "Clair checkout not found: #{CLAIR_ROOT}" unless File.directory?(CLAIR_ROOT)
end

def clair_environment
  {
    "CLAIR_TARGET" => clair_target,
    "CLAIR_TARGET_OS" => clair_target_os,
    "CLAIR_BUILD_PROFILE" => CLAIR_BUILD_PROFILE
  }
end

def prepare_clair!
  ensure_clair_checkout!
  ok = system(clair_environment, "rake", "build", chdir: CLAIR_ROOT)
  abort "command failed: rake build" unless ok
end

def prepare_clair_tests!
  ensure_clair_checkout!
  ok = system(clair_environment, "rake", "test-build", chdir: CLAIR_ROOT)
  abort "command failed: rake test-build" unless ok
end

def clair_test_registry_generator
  base = File.join(
    CLAIR_ROOT,
    "build",
    "host",
    clair_host_target,
    "tools",
    "gen-clair-test-registry"
  )
  candidates = [base, "#{base}.exe"].select do |path|
    File.file?(path) && File.executable?(path)
  end

  abort "Clair test registry generator not found: #{base}" if candidates.empty?
  abort "multiple Clair test registry generators found: #{candidates.join(', ')}" if candidates.length > 1
  candidates.first
end

def generate_test_registry!
  output_dir = File.join(ROOT, "build", "tests", "generated")
  FileUtils.mkdir_p output_dir
  run! clair_test_registry_generator,
       "--tests-dir", File.join(ROOT, "tests"),
       "--output-dir", output_dir,
       "--package", "Tests",
       "--registry-package", "Tests.Generated_Registry"
end

desc "Show the resolved Fasyn development context"
task :info do
  puts "fasyn_root=#{ROOT}"
  puts "clair_root=#{CLAIR_ROOT}"
  puts "clair_present=#{File.directory?(CLAIR_ROOT)}"
  puts "clair_host_target=#{clair_host_target}"
  puts "clair_target=#{clair_target}"
  puts "clair_target_os=#{clair_target_os}"
  puts "clair_build_profile=#{CLAIR_BUILD_PROFILE}"
end

desc "Build the Fasyn core library and compile Clair-backed runtime sources"
task :build do
  prepare_clair!
  run! "gprbuild", *clair_gpr_switches, "-P", "fasyn.gpr"
  run! "gprbuild", *clair_gpr_switches, "-c", "-r", "-P", "fasyn_runtime.gpr"
end

task default: :build

desc "Build and run unit tests through Clair.Test"
task :test do
  prepare_clair_tests!
  generate_test_registry!
  run! "gprbuild", *clair_gpr_switches(include_tests: true), "-P", "fasyn_tests.gpr"
  fixture = File.join(ROOT, "build", "tests", "bin", "fasyn_classic_fixture")
  run!({ "FASYN_CLASSIC_FIXTURE" => fixture },
       File.join(ROOT, "build", "tests", "bin", "fasyn_unit_tests"))
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
  task nginx: :test do
    nginx = nginx_executable!
    fixture = File.join(ROOT, "build", "tests", "bin", "fasyn_nginx_fixture")
    abort "NGINX fixture not found: #{fixture}" unless File.executable?(fixture)

    Dir.mktmpdir("fasyn-nginx-") do |dir|
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

desc "Remove Fasyn build products"
task :clean do
  FileUtils.rm_rf File.join(ROOT, "build")
end

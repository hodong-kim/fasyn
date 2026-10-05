#!/usr/bin/env ruby
# frozen_string_literal: true
# ============================================================================
# fasyn_exchange_callback_churn.rb
# Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# ============================================================================

require "json"
require "open3"
require "rbconfig"
require "timeout"

executable = File.expand_path(ARGV.fetch(0))
batches = Integer(ENV.fetch("FASYN_EXCHANGE_CALLBACK_BATCHES", "50"), 10)
batch_size = Integer(
  ENV.fetch("FASYN_EXCHANGE_CALLBACK_BATCH_SIZE", "100"), 10
)
trace = ENV.fetch("FASYN_EXCHANGE_CALLBACK_TRACE", "0") == "1"
only_case = ENV["FASYN_EXCHANGE_CALLBACK_ONLY_CASE"]
raise "Fasyn Exchange callback batches must be at least 8" unless batches >= 8
unless batch_size.positive?
  raise "Fasyn Exchange callback batch size must be positive"
end

host_os = RbConfig::CONFIG.fetch("host_os")
platform =
  if host_os.include?("linux")
    "linux"
  elsif host_os.include?("freebsd")
    "freebsd"
  else
    raise "unsupported Fasyn Exchange callback platform: #{host_os}"
  end

CASES = {
  "params_finish" => 1,
  "params_payload_finish" => 8
}.freeze
SELECTED_CASES =
  if only_case.nil?
    CASES.keys
  elsif CASES.key?(only_case)
    [only_case]
  else
    raise "unknown Fasyn Exchange callback case: #{only_case}"
  end


def capture_freebsd(*argv)
  stdout, stderr, status = Open3.capture3(*argv)
  unless status.success?
    raise "FreeBSD resource probe failed (#{argv.join(' ')}): #{stderr.strip}"
  end
  stdout
end


def resource_sample(platform, pid, batch, requests)
  if platform == "linux"
    wanted = {
      "VmRSS" => "rss_kib",
      "VmSize" => "vmsize_kib",
      "Threads" => "threads"
    }
    values = {}
    File.foreach("/proc/#{pid}/status") do |line|
      key, rest = line.split(":", 2)
      target = wanted[key]
      next if target.nil?

      values[target] = Integer(rest.split.fetch(0), 10)
    end
    missing = wanted.values.reject { |key| values.key?(key) }
    unless missing.empty?
      raise "Linux process metrics missing: #{missing.join(', ')}"
    end
    values["fds"] = Dir.children("/proc/#{pid}/fd").length
  else
    fields = capture_freebsd(
      "/bin/ps", "-o", "rss=", "-o", "vsz=", "-p", pid.to_s
    ).split
    unless fields.length == 2
      raise "FreeBSD ps memory probe malformed: #{fields.inspect}"
    end
    values = {
      "rss_kib" => Integer(fields.fetch(0), 10),
      "vmsize_kib" => Integer(fields.fetch(1), 10),
      "threads" => capture_freebsd(
        "/usr/bin/procstat", "-t", "-h", pid.to_s
      ).lines.count { |line| !line.strip.empty? },
      "fds" => capture_freebsd(
        "/usr/bin/procstat", "-f", "-h", pid.to_s
      ).lines.count do |line|
        item = line.split
        item.length >= 3 && item.fetch(2).match?(/\A[0-9]+\z/)
      end
    }
  end

  values.merge("batch" => batch, "requests" => requests)
end


def median(values)
  sorted = values.sort
  middle = sorted.length / 2
  return sorted.fetch(middle) if sorted.length.odd?

  (sorted.fetch(middle - 1) + sorted.fetch(middle)) / 2.0
end


def read_line(io, timeout, label)
  line = Timeout.timeout(timeout) { io.gets }
  if line.nil?
    raise "Fasyn Exchange callback fixture closed while waiting for #{label}"
  end

  line.strip
end


def run_case(executable, platform, batches, batch_size, label, callbacks, trace)
  samples = []

  Open3.popen3(executable, label, batches.to_s, batch_size.to_s) do |
    stdin, stdout, stderr, wait_thread
  |
    pid = wait_thread.pid
    ready = read_line(stdout, 10, "#{label} readiness")
    unless ready == "ready"
      raise(
        "Fasyn Exchange callback readiness mismatch for #{label}: " \
        "#{ready.inspect}"
      )
    end

    samples << resource_sample(platform, pid, 0, 0)
    stdin.puts("continue")
    stdin.flush

    batches.times do |offset|
      expected = offset + 1
      observed = Integer(
        read_line(stdout, 10, "#{label} batch #{expected}"), 10
      )
      unless observed == expected
        raise "Fasyn Exchange callback batch mismatch: " \
              "#{observed} != #{expected}"
      end
      samples << resource_sample(
        platform, pid, expected, expected * batch_size
      )
      stdin.puts("continue")
      stdin.flush
    end

    stdin.close
    status = Timeout.timeout(10) { wait_thread.value }
    fixture_stderr = stderr.read
    unless fixture_stderr.empty?
      raise "Fasyn Exchange callback fixture wrote stderr: " \
            "#{fixture_stderr.inspect}"
    end
    unless status.success?
      raise "Fasyn Exchange callback fixture failed: #{status.inspect}"
    end
  end

  baseline = samples.first
  final = samples.last
  late = samples[(samples.length / 2)..]
  split = late.length / 2
  earlier = late[0, split]
  later = late[split, late.length]
  earlier_median = median(earlier.map { |item| item.fetch("rss_kib") })
  later_median = median(later.map { |item| item.fetch("rss_kib") })
  allowance = [512, (earlier_median * 0.05).ceil].max
  rss_values = samples.map { |item| item.fetch("rss_kib") }
  rss_deltas = rss_values.each_cons(2).map { |before, after| after - before }
  positive_rss_steps = rss_deltas.count(&:positive?)
  sustained_step_threshold = (rss_deltas.length * 3 + 3) / 4
  total_rss_growth = final.fetch("rss_kib") - baseline.fetch("rss_kib")
  sustained_growth =
    total_rss_growth > 256 && positive_rss_steps >= sustained_step_threshold

  report = {
    "platform" => platform,
    "kind" => "fasyn_exchange_callback_churn",
    "case" => label,
    "application_callbacks_per_request" => callbacks,
    "requests" => batches * batch_size,
    "batches" => batches,
    "batch_size" => batch_size,
    "baseline_rss_kib" => baseline.fetch("rss_kib"),
    "final_rss_kib" => final.fetch("rss_kib"),
    "peak_rss_kib" => rss_values.max,
    "baseline_vmsize_kib" => baseline.fetch("vmsize_kib"),
    "final_vmsize_kib" => final.fetch("vmsize_kib"),
    "peak_vmsize_kib" => samples.map { |item| item.fetch("vmsize_kib") }.max,
    "baseline_threads" => baseline.fetch("threads"),
    "final_threads" => final.fetch("threads"),
    "baseline_fds" => baseline.fetch("fds"),
    "final_fds" => final.fetch("fds"),
    "earlier_tail_median_rss_kib" => earlier_median,
    "later_tail_median_rss_kib" => later_median,
    "rss_stability_allowance_kib" => allowance,
    "rss_total_growth_kib" => total_rss_growth,
    "positive_rss_steps" => positive_rss_steps,
    "rss_step_count" => rss_deltas.length
  }
  puts JSON.generate(report)
  if trace
    puts JSON.generate(
      "case" => label,
      "resource_samples" => samples
    )
  end

  failures = []
  if final.fetch("threads") != baseline.fetch("threads")
    failures << "thread count changed"
  end
  failures << "FD count changed" if final.fetch("fds") != baseline.fetch("fds")
  if later_median > earlier_median + allowance
    failures << "RSS tail did not plateau"
  end
  if final.fetch("rss_kib") > later_median + allowance
    failures << "final RSS escaped plateau"
  end
  failures << "sustained RSS growth" if sustained_growth

  if failures.empty?
    puts "[PASS] Fasyn Exchange callback #{label} resource stability"
  end
  [report, failures]
end

failures = []
SELECTED_CASES.each do |label|
  report, case_failures = run_case(
    executable, platform, batches, batch_size, label, CASES.fetch(label), trace
  )
  next if case_failures.empty?

  failures << "#{label}: #{case_failures.join(', ')}: #{report.inspect}"
end

unless failures.empty?
  raise "Fasyn Exchange callback churn failed: #{failures.join(' | ')}"
end

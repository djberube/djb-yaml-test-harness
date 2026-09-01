# frozen_string_literal: true

require 'open3'
require_relative 'config'

# Builds and runs the per-parser images.
#
# Every parser runs in a container, including the ones that would work on the
# host. That is deliberate: the point of the matrix is that a row means the
# same thing for every parser, and "whatever version happened to be installed"
# does not. Each image pins its library version, so a result is attributable to
# a specific parser build rather than to the machine it ran on.
#
# Images build on first use and are cached by tag afterwards. Bump a tag in the
# parser definition when its Dockerfile changes in a way that should invalidate
# an already-built image.
module Docker
  Error = Class.new(StandardError)

  @built = {}

  class << self
    def available?
      return @available unless @available.nil?

      _, status = Open3.capture2e('docker', 'version', '--format', '{{.Server.Version}}')
      @available = status.success?
    rescue Errno::ENOENT
      @available = false
    end

    def image_exists?(tag)
      _, status = Open3.capture2e('docker', 'image', 'inspect', tag)
      status.success?
    end

    # Builds `tag` from docker/<dir> unless it is already present. Docker's own
    # layer cache makes a redundant build cheap, but these images compile C
    # libraries from source, so "cheap" is still tens of seconds -- hence the
    # explicit inspect before building.
    def ensure_image(dir, tag)
      return tag if @built[tag]

      raise Error, 'docker is not available; install it or pass --only for host parsers' unless available?

      if image_exists?(tag)
        @built[tag] = true
        return tag
      end

      context = File.join(Config::DOCKER_DIR, dir)
      raise Error, "no docker context at #{context}" unless File.directory?(context)

      warn "  building #{tag} (first use; cached afterwards, may take a few minutes)..."
      out, status = Open3.capture2e('docker', 'build', '-t', tag, context)
      raise Error, "docker build failed for #{tag}:\n#{out}" unless status.success?

      @built[tag] = true
      tag
    end

    # argv that runs `inner_cmd` with `host_dir` mounted read-only at /work.
    #
    # --network none because a YAML parser reading a local document has no
    # business dialing out, and the suite contains documents specifically
    # designed to look like URLs and tag handles.
    def run_argv(tag, host_dir, inner_cmd)
      [
        'docker', 'run', '--rm', '-i',
        '--network', 'none',
        '-v', "#{host_dir}:/work:ro",
        '-w', '/work',
        tag, *inner_cmd
      ]
    end
  end
end

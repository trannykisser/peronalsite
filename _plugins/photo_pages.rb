# frozen_string_literal: true

# Photo pages generator
# =====================
# Creates one page per image in the photo folder, filled in from the image's
# own metadata (EXIF / XMP / IPTC, as written by GIMP, a camera, etc.).
# Full documentation: _plugins/README.md
#
# Needs the `exiftool` program on the machine that builds the site
# (Debian/Ubuntu: `sudo apt install libimage-exiftool-perl`). Without it the
# site still builds, but titles fall back to file names.

require "json"
require "open3"
require "time"

module PhotoPages
  DEFAULTS = {
    "dir"        => "photo",
    "layout"     => "photo",
    "extensions" => %w[.jpg .jpeg .png .gif .webp .tif .tiff .avif],
  }.freeze

  # Metadata tags to try, in order of preference. Names are exiftool's.
  TITLE_TAGS       = %w[Title ObjectName Headline XPTitle].freeze
  DESCRIPTION_TAGS = %w[Description ImageDescription Caption-Abstract XPComment UserComment].freeze
  DATE_TAGS        = %w[DateCreated DateTimeOriginal CreateDate].freeze
  KEYWORD_TAGS     = %w[Subject Keywords XPKeywords].freeze

  # ---------------------------------------------------------------------------
  # Reading metadata
  # ---------------------------------------------------------------------------
  module Metadata
    module_function

    # Results are cached per file (path + size + mtime) so `jekyll serve`
    # rebuilds don't re-read unchanged images.
    CACHE = {}

    def exiftool?
      return @exiftool if defined?(@exiftool)

      @exiftool = system("exiftool", "-ver", out: File::NULL, err: File::NULL) ? true : false
    rescue SystemCallError
      @exiftool = false
    end

    # Returns { absolute_path => { "Tag" => value, ... } } for the given files,
    # using a single exiftool process for all uncached files.
    def read(paths)
      keyed = paths.to_h { |p| [p, cache_key(p)] }
      missing = paths.reject { |p| CACHE.key?(keyed[p]) }

      if missing.any? && exiftool?
        out, err, _status = Open3.capture3("exiftool", "-q", "-json", "-charset", "filename=utf8", *missing)
        err.each_line { |line| Jekyll.logger.warn("PhotoPages:", line.strip) unless line.strip.empty? }
        begin
          JSON.parse(out.empty? ? "[]" : out).each do |entry|
            path = entry.delete("SourceFile")
            CACHE[keyed[path]] = clean(entry) if keyed.key?(path)
          end
        rescue JSON::ParserError => e
          Jekyll.logger.warn("PhotoPages:", "could not parse exiftool output (#{e.message})")
        end
      end

      paths.to_h { |p| [p, CACHE.fetch(keyed[p], {})] }
    end

    def cache_key(path)
      stat = File.stat(path)
      [path, stat.size, stat.mtime.to_f]
    end

    # Drop exiftool's placeholders for binary blobs and empty values.
    def clean(entry)
      entry.reject do |_tag, value|
        value.nil? ||
          (value.is_a?(String) && (value.strip.empty? || value.start_with?("(Binary data")))
      end
    end

    # First non-empty value among the given tags, as a string.
    def first(meta, tags)
      tags.each do |tag|
        value = meta[tag]
        value = value.first if value.is_a?(Array)
        return value.to_s.strip unless value.nil? || value.to_s.strip.empty?
      end
      nil
    end

    # exiftool dates look like "2026:02:20 18:58:00+01:00" (time and zone optional).
    def parse_date(value)
      m = value.to_s.match(/\A(\d{4}):(\d{2}):(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?/)
      return nil unless m

      parts = m.captures[0, 6].map { |c| c.to_i }
      zone = m[7] == "Z" ? "+00:00" : m[7]
      zone ? Time.new(*parts, zone) : Time.new(*parts)
    rescue ArgumentError
      nil # e.g. "0000:00:00 00:00:00"
    end

    def keywords(meta)
      KEYWORD_TAGS.each do |tag|
        value = meta[tag]
        next if value.nil?

        list = value.is_a?(Array) ? value : value.to_s.split(/\s*[,;]\s*/)
        list = list.map { |k| k.to_s.strip }.reject(&:empty?)
        return list if list.any?
      end
      []
    end

    # Date the file was first committed to git. Needs full history
    # (the workflow checks out with fetch-depth: 0).
    def git_added_date(source, path)
      out, status = Open3.capture2(
        "git", "-C", source, "log", "--follow", "--diff-filter=A", "--format=%aI", "--",
        path.delete_prefix("#{source}/")
      )
      line = out.lines.last&.strip
      status.success? && line && !line.empty? ? Time.iso8601(line) : nil
    rescue SystemCallError, ArgumentError
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # The generated page
  # ---------------------------------------------------------------------------
  class PhotoPage < Jekyll::PageWithoutAFile
    def initialize(site, dir, slug, file, meta, layout)
      super(site, site.source, dir, "#{slug}.html")
      self.content = ""

      title = Metadata.first(meta, TITLE_TAGS) || file.basename
      date  = Metadata.parse_date(Metadata.first(meta, DATE_TAGS)) ||
              Metadata.git_added_date(site.source, file.path) ||
              File.mtime(file.path)

      data.merge!(
        "layout"      => layout,
        "photo"       => true,
        "title"       => title,
        "description" => Metadata.first(meta, DESCRIPTION_TAGS),
        "date"        => date,
        "tags"        => Metadata.keywords(meta),
        "image"       => file.name,
        "image_path"  => file.relative_path,
        "exif"        => summary(meta),
        "metadata"    => meta
      )
    end

    private

    def summary(meta)
      make  = Metadata.first(meta, %w[Make])
      model = Metadata.first(meta, %w[Model])
      camera = [make, model].compact
      camera = [model] if make && model&.start_with?(make) # avoid "Canon Canon EOS ..."

      {
        "camera"       => camera.empty? ? nil : camera.join(" "),
        "lens"         => Metadata.first(meta, %w[LensModel LensID Lens]),
        "focal_length" => Metadata.first(meta, %w[FocalLength]),
        "aperture"     => Metadata.first(meta, %w[FNumber Aperture]),
        "exposure"     => Metadata.first(meta, %w[ExposureTime ShutterSpeed]),
        "iso"          => Metadata.first(meta, %w[ISO]),
        "width"        => meta["ImageWidth"],
        "height"       => meta["ImageHeight"],
        "author"       => Metadata.first(meta, %w[Creator Artist By-line]),
        "copyright"    => Metadata.first(meta, %w[Rights Copyright CopyrightNotice]),
        "software"     => Metadata.first(meta, %w[CreatorTool Software]),
      }.compact
    end
  end

  # ---------------------------------------------------------------------------
  # The generator
  # ---------------------------------------------------------------------------
  class Generator < Jekyll::Generator
    safe true
    priority :high # run before other generators so they can see the new pages

    def generate(site)
      config = DEFAULTS.merge(site.config["photo_pages"] || {})
      dir    = config["dir"].to_s.gsub(%r{\A/+|/+\z}, "")
      layout = config["layout"]
      exts   = Array(config["extensions"]).map { |e| e.to_s.downcase }

      unless site.layouts.key?(layout)
        Jekyll.logger.warn("PhotoPages:", "layout '#{layout}' not found in _layouts/")
      end

      images = site.static_files
        .select { |f| File.dirname(f.relative_path).delete_prefix("/") == dir }
        .select { |f| exts.include?(f.extname.downcase) }
        .sort_by(&:name)
      return if images.empty?

      unless Metadata.exiftool?
        Jekyll.logger.warn("PhotoPages:", "exiftool not found - titles/descriptions fall back to file names.")
        Jekyll.logger.warn("", "Install it with: sudo apt install libimage-exiftool-perl")
      end

      existing = site.pages.select { |p| p.dir == "/#{dir}/" }
      claimed  = existing.map { |p| p.data["image"] }.compact # hand-written pages win
      taken    = existing.map(&:basename)
      metadata = Metadata.read(images.map(&:path))

      images.each do |file|
        next if claimed.include?(file.name)

        slug = unique_slug(file, taken)
        unless slug
          Jekyll.logger.warn("PhotoPages:", "skipped #{file.relative_path} (its page name is already used)")
          next
        end

        taken << slug
        site.pages << PhotoPage.new(site, dir, slug, file, metadata[file.path], layout)
      end
    end

    private

    # "kasane tito.png" -> "kasane-tito"; "HR.png" and "HR.jpg" -> "hr", "hr-jpg".
    def unique_slug(file, taken)
      base = Jekyll::Utils.slugify(file.basename)
      base = Jekyll::Utils.slugify("photo-#{file.basename}", mode: "latin") if base.empty?
      [base, "#{base}-#{file.extname.delete('.').downcase}"].find { |s| !s.empty? && !taken.include?(s) }
    end
  end
end

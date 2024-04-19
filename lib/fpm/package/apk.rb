require "erb"
require "fpm/namespace"
require "fpm/package"
require "fpm/errors"
require "fpm/util"
require "backports/latest"
require "fileutils"
require "digest"
require 'digest/sha1'

# Support for Alpine packages (.apk files)
#
# This class supports both input and output of packages.
class FPM::Package::APK< FPM::Package

  TAR_CHUNK_SIZE = 512
  TAR_TYPEFLAG_OFFSET = 156
  TAR_NAME_OFFSET_START = 0
  TAR_NAME_OFFSET_END = 99
  TAR_LENGTH_OFFSET_START = 124
  TAR_LENGTH_OFFSET_END = 135
  TAR_CHECKSUM_OFFSET_START = 148
  TAR_CHECKSUM_OFFSET_END = 155
  TAR_MAGIC_START = 257
  TAR_MAGIC_END = 264
  TAR_UID_START = 108
  TAR_UID_END = 115
  TAR_GID_START = 116
  TAR_GID_END = 123
  TAR_UNAME_START = 265
  TAR_UNAME_END = 296
  TAR_GNAME_START = 297
  TAR_GNAME_END = 328
  TAR_MAJOR_START = 329
  TAR_MAJOR_END = 336
  TAR_MINOR_START = 337
  TAR_MINOR_END = 344

  private

  # Get the name of this package. See also FPM::Package#name
  #
  # This accessor actually modifies the name if it has some invalid or unwise
  # characters.
  def name
    if @name =~ /[A-Z]/
      logger.warn("apk packages should not have uppercase characters in their names")
      @name = @name.downcase
    end

    if @name.include?("_")
      logger.warn("apk packages should not include underscores")
      @name = @name.gsub(/[_]/, "-")
    end

    if @name.include?(" ")
      logger.warn("apk packages should not contain spaces")
      @name = @name.gsub(/[ ]/, "-")
    end

    return @name
  end

  def prefix
    return (attributes[:prefix] or "/")
  end

  def architecture

    # "native" in apk should be "noarch"
    if @architecture.nil? or @architecture == "native"
      @architecture = "noarch"
    end
    return @architecture
  end

  def input(input_path)
    logger.error("apk extraction is not yet implemented")
  end

  def output(output_path)
    output_check(output_path)

    datatar_path = create_data_tar
    controltar_path = create_control_tar(datatar_path)

    concat_zip_tars(controltar_path, datatar_path, output_path)

    logger.warn("apk output does not currently sign packages.")
    logger.warn("It's recommended that your package be installed with '--allow-untrusted'")
  end

  def write_pkginfo(base_path, datahash)
    pkginfo = ""

    pkginfo << "# Generated by fpm\n"
    pkginfo << "pkgname = #{@name}\n"
    pkginfo << "pkgver = #{to_s("FULLVERSION")}\n"
    pkginfo << "arch = #{architecture()}\n"
    pkginfo << "pkgdesc = #{description()}\n"
    pkginfo << "url = #{url()}\n"
    pkginfo << "size = 102400\n" # totally magic, not sure what it's used for.

    # write depends lines
    for dependency in dependencies()
      pkginfo << "depend = #{dependency}\n"
    end

    pkginfo << "datahash = #{datahash}\n"

    File.write("#{base_path}/.PKGINFO", pkginfo)
  end

  def create_data_tar
    datatar_path = build_path("data.tar")
    tar_path(staging_path(""), datatar_path)

    hash_datatar(datatar_path)

    datatar_path
  end

  def create_control_tar(datatar_path)
    control_path = build_path("control")
    controltar_path = build_path("control.tar")
    FileUtils.mkdir(control_path)

    datatar = File.read(datatar_path)
    datahash = Digest::SHA256.hexdigest(datatar)

    begin
      write_pkginfo(control_path, datahash)
      write_control_scripts(control_path)
      tar_path(control_path, controltar_path)
    ensure
      FileUtils.rm_r(control_path)
    end

    cut_tar_record(controltar_path)

    controltar_path
  end

  # Writes each control script from template into the build path,
  # in the folder given by [base_path]
  def write_control_scripts(base_path)

    scripts = {}

    scripts = register_script('post-install',   :after_install,   scripts)
    scripts = register_script('pre-install',   :before_install,  scripts)
    scripts = register_script('pre-upgrade',   :before_upgrade,  scripts)
    scripts = register_script('post-upgrade',   :after_upgrade,  scripts)
    scripts = register_script('pre-deinstall',  :before_remove,   scripts)
    scripts = register_script('post-deinstall', :after_remove,    scripts)

    scripts.each do |key, content|

      File.write("#{base_path}/.#{key}", content)
    end
  end

  # Convenience method for 'write_control_scripts' to register control scripts
  # if they exist.
  def register_script(key, value, hash)

    if(script?(value))
      hash[key] = scripts[value]
    end
    return hash
  end

  # Removes the end-of-tar records from the given [target_path].
  # End of tar records are two contiguous empty tar records at the end of the file
  # Taken together, they comprise 1k of null data.
  def cut_tar_record(target_path)

    temporary_target_path = target_path + "~"

    record_length = 0
    empty_records = 0

    open(temporary_target_path, "wb") do |target_file|

      # Scan to find the location of the two contiguous null records
      open(target_path, "rb") do |file|

        until(empty_records == 2)

          header = file.read(TAR_CHUNK_SIZE)

          # clear off ownership info
          header = replace_ownership_headers(header, true)

          typeflag = header[TAR_TYPEFLAG_OFFSET]
          ascii_length = header[TAR_LENGTH_OFFSET_START..TAR_LENGTH_OFFSET_END]

          if(file.eof?())
            raise StandardError.new("Invalid tar stream, eof before end-of-tar record")
          end

          if(typeflag == "\0")
            empty_records += 1
            next
          end

          record_length = ascii_length.to_i(8)
          record_length = determine_record_length(record_length)

          target_file.write(header)
          target_file.write(file.read(record_length))
        end
      end
    end

    FileUtils::mv(temporary_target_path, target_path)
  end

  # Rewrites the tar file located at the given [target_tar_path]
  # to have its record headers use a simple checksum,
  # and the apk sha1 hash extension.
  def hash_datatar(target_path)

    header = extension_header = ""
    data = extension_data = ""
    record_length = extension_length = 0
    empty_records = 0

    temporary_file_name = target_path + "~"

    target_file = open(temporary_file_name, "wb")
    file = open(target_path, "rb")
    begin

      until(file.eof?() || empty_records == 2)

        header = file.read(TAR_CHUNK_SIZE)
        typeflag = header[TAR_TYPEFLAG_OFFSET]
        record_length = header[TAR_LENGTH_OFFSET_START..TAR_LENGTH_OFFSET_END].to_i(8)

        data = ""
        record_length = determine_record_length(record_length)

        until(data.length == record_length)
          data << file.read(TAR_CHUNK_SIZE)
        end

        # Clear ownership fields
        header = replace_ownership_headers(header, false)

        # If it's not a null record, do extension hash.
        if(typeflag != "\0")
          extension_header = header.dup()

          extension_header = replace_ownership_headers(extension_header, true)

          # directories have a magic string inserted into their name
          full_record_path = extension_header[TAR_NAME_OFFSET_START..TAR_NAME_OFFSET_END].delete("\0")
          full_record_path = add_paxstring(full_record_path)

          # hash data contents with sha1, if there is any content.
          if(typeflag == '5')

            extension_data = ""

            # ensure it doesn't end with a slash
            if(full_record_path[full_record_path.length-1] == '/')
              full_record_path = full_record_path.chop()
            end
          else
            extension_data = hash_record(data)
          end

          full_record_path = pad_string_to(full_record_path, 100)
          extension_header[TAR_NAME_OFFSET_START..TAR_NAME_OFFSET_END] = full_record_path

          extension_header[TAR_TYPEFLAG_OFFSET] = 'x'
          extension_header[TAR_LENGTH_OFFSET_START..TAR_LENGTH_OFFSET_END] = extension_data.length.to_s(8).rjust(12, '0')
          extension_header = checksum_header(extension_header)

          # write extension record
          target_file.write(extension_header)
          target_file.write(extension_data)
        else
          empty_records += 1
        end

        # write header and data to target file.
        target_file.write(header)
        target_file.write(data)
      end
      FileUtils.mv(temporary_file_name, target_path)
    ensure
      file.close()
      target_file.close()
    end
  end

  # Concatenates each of the given [apath] and [bpath] into the given [target_path]
  def concat_zip_tars(apath, bpath, target_path)

    temp_apath = apath + "~"
    temp_bpath = bpath + "~"

    # zip each path separately
    Zlib::GzipWriter.open(temp_apath) do |target_writer|
      open(apath, "rb") do |file|
        until(file.eof?())
          target_writer.write(file.read(4096))
        end
      end
    end

    Zlib::GzipWriter.open(temp_bpath) do |target_writer|
      open(bpath, "rb") do |file|
        until(file.eof?())
          target_writer.write(file.read(4096))
        end
      end
    end

    # concat both into one.
    File.open(target_path, "wb") do |target_writer|
      open(temp_apath, "rb") do |file|
        until(file.eof?())
          target_writer.write(file.read(4096))
        end
      end
      open(temp_bpath, "rb") do |file|
        until(file.eof?())
          target_writer.write(file.read(4096))
        end
      end
    end
  end

  # Rounds the given [record_length] to the nearest highest evenly-divisble number of 512.
  def determine_record_length(record_length)

    sans_size = TAR_CHUNK_SIZE-1

    if(record_length % TAR_CHUNK_SIZE != 0)
      record_length = (record_length + sans_size) & ~sans_size;
    end
    return record_length
  end

  # Checksums the entire contents of the given [header]
  # Writes the resultant checksum into indices 148-155 of the same [header],
  # and returns the modified header.
  # 148-155 is the "size" range in a tar/ustar header.
  def checksum_header(header)

    # blank out header checksum
    replace_string_range(header, TAR_CHECKSUM_OFFSET_START, TAR_CHECKSUM_OFFSET_END, ' ')

    # calculate new checksum
    checksum = 0

    for i in 0..(TAR_CHUNK_SIZE-1)
      checksum += header.getbyte(i)
    end

    checksum = checksum.to_s(8).rjust(6, '0')
    header[TAR_CHECKSUM_OFFSET_START..TAR_CHECKSUM_OFFSET_END-2] = checksum
    header[TAR_CHECKSUM_OFFSET_END-1] = "\0"
    return header
  end

  # SHA-1 hashes the given data, then places it in the APK hash string format
  # then returns.
  def hash_record(data)

    # %u %s=%s\n
    # len name=hash

    hash = Digest::SHA1.hexdigest(data)
    name = "APK-TOOLS.checksum.SHA1"

    ret = "#{name}=#{hash}\n"

    # the length requirement needs to know its own length too, because the length
    # is the entire length of the line, not just the contents.
    length = ret.length
    line_length = length.to_s
    length += line_length.length
    candidate_ret = "#{line_length} #{ret}"

    if(candidate_ret.length != length)
      length += 1
      candidate_ret = "#{length.to_s} #{ret}"
    end

    ret = candidate_ret

    # pad out the result
    ret = pad_string_to(ret, TAR_CHUNK_SIZE)
    return ret
  end

  # Tars the current contents of the given [path] to the given [target_path].
  def tar_path(path, target_path)

    # Change directory to the source path, and glob files
    # This is done so that we end up with a "flat" archive, that doesn't
    # have any path artifacts from the packager's absolute path.
    ::Dir::chdir(path) do
      entries = ::Dir::glob("**", File::FNM_DOTMATCH)

      args =
      [
        tar_cmd,
        "-f",
        target_path,
        "-c"
      ]

      # Move pkginfo to the front, if it exists.
      for i in (0..entries.length)
        if(entries[i] == ".PKGINFO")
          entries[i] = entries[0]
          entries[0] = ".PKGINFO"
          break
        end
      end

      # add entries to arguments.
      entries.each do |entry|
        unless(entry == '..' || entry == '.')
          args = args << entry
        end
      end

      safesystem(*args)
    end
  end

  # APK adds a "PAX" magic string into most directory names.
  # This takes an unchanged directory name and "paxifies" it.
  def add_paxstring(ret)

    pax_slash = ret.rindex('/')
    if(pax_slash == nil)
      pax_slash = 0
    else
      pax_slash = ret.rindex('/', pax_slash-1)
      if(pax_slash == nil || pax_slash < 0)
        pax_slash = 0
      end
    end

    ret = ret.insert(pax_slash, "/PaxHeaders.14670/")
    ret = ret.sub("//", "/")
    return ret
  end

  # Appends null zeroes to the end of [ret] until it is divisible by [length].
  # Returns the padded result.
  def pad_string_to(ret, length)

    until(ret.length % length == 0)
      ret << "\0"
    end
    return ret
  end

  # Replaces every character between [start] and [finish] in the given [str]
  # with [character].
  def replace_string_range(str, start, finish, character)

    for i in (start..finish)
      str[i] = character
    end

    return str
  end

  # Nulls out the ownership bits of the given tar [header].
  def replace_ownership_headers(header, nullify_names)

    # magic
    header[TAR_MAGIC_START..TAR_MAGIC_END] = "ustar\0" + "00"

    # ids
    header = replace_string_range(header, TAR_UID_START, TAR_UID_END, "0")
    header = replace_string_range(header, TAR_GID_START, TAR_GID_END, "0")
    header[TAR_GID_END] = "\0"
    header[TAR_UID_END] = "\0"

    # names
    if(nullify_names)
      header = replace_string_range(header, TAR_UNAME_START, TAR_UNAME_END, "\0")
      header = replace_string_range(header, TAR_GNAME_START, TAR_GNAME_END, "\0")

      # major/minor
      header[TAR_MAJOR_START..TAR_MAJOR_END] = "0".rjust(8, '0')
      header[TAR_MINOR_START..TAR_MINOR_END] = "0".rjust(8, '0')
      header[TAR_MAJOR_END] = "\0"
      header[TAR_MINOR_END] = "\0"
    else
      header[TAR_UNAME_START..TAR_UNAME_END] = pad_string_to("root", 32)
      header[TAR_GNAME_START..TAR_GNAME_END] = pad_string_to("root", 32)
    end

    return header
  end

  def to_s(format=nil)
    return super("NAME_FULLVERSION_ARCH.TYPE") if format.nil?
    return super(format)
  end

  public(:input, :output, :architecture, :name, :prefix, :converted_from, :to_s)
end

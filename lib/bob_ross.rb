require 'logger'
require 'singleton'
require 'openssl'
require 'cgi'

class BobRoss
  include Singleton
  
  autoload :Plugin, File.expand_path('../bob_ross/plugin', __FILE__)
  autoload :BackendHelpers, File.expand_path('../bob_ross/backends/helpers', __FILE__)
  autoload :ImageMagickBackend, File.expand_path('../bob_ross/backends/imagemagick', __FILE__)
  autoload :LibVipsBackend, File.expand_path('../bob_ross/backends/libvips', __FILE__)

  attr_reader :host, :plugins
  attr_accessor :logger

  def initialize
    @plugins = {}
    @logger = Logger.new(STDOUT)
  end
  
  def configure(options)
    options = normalize_options(options)
    
    @host = options.delete(:host)
    @hmac = options.delete(:hmac)
    @logger = options.delete(:logger)
    @transformations = options
    @backend = options.delete(:backend)
  end
  
  def backend
    @backend || BobRoss::ImageMagickBackend
  end
  
  def register_plugin(plugin)
    plugin.mime_types.each do |mime_type|
      @plugins[mime_type] = plugin
    end
  end
  
  def normalize_options(options)
    result = options.dup
    result.delete(:hmac)
    
    if options[:hmac].is_a?(String)
      result[:hmac] = { key: options[:hmac] }
    elsif options[:hmac]
      result[:hmac] = { key: options[:hmac][:key] }
      if options[:hmac][:attributes].is_a?(Array)
        result[:hmac][:attributes] = options[:hmac][:attributes].map(&:to_sym)
      elsif options[:hmac][:attributes]
        result[:hmac][:attributes] = [options[:hmac][:attributes].to_sym]
      else
        result[:hmac][:attributes] = [:transformations, :hash]
      end
    end

    result
  end
  
  def url(hash, options = {})
    if host = options[:host] || @host
      File.join(host, path(hash, options))
    else
      path(hash, options)
    end
  end

  def path(hash, options = {})
    options = normalize_options(options)

    hmac_options = if options[:hmac]
      @hmac ? @hmac.merge(options[:hmac]){ |k,o,n| o } : options[:hmac]
    else
      @hmac
    end
    
    transforms = encode_transformations(options) + encode_transformations(@transformations)
    
    url = if fmt = (options[:format] || @transformations[:format])
      ".#{fmt}"
    else
      ""
    end
    
    url = if filename = (options[:filename] || @transformations[:filename])
      hash + "/#{CGI::escape("#{filename}")}" + url
    else
      hash + url
    end

    if hmac_options
      hmac_data = ''

      hmac_options[:attributes].each do |attr|
        case attr
        when :hash
          hmac_data << hash
        when :transformations
          hmac_data << transforms
        when :format
          hmac_data << options[:format].to_s if options[:format]
        end
      end
      
      hmac = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), hmac_options[:key], hmac_data)
      transforms = "H#{hmac}#{transforms}"
    end
    
    if !transforms.empty?
      "/#{CGI::escape(transforms)}/#{url}"
    else
      "/#{url}"
    end
  end

  def calculate_hmac(data, options={})
    options = normalize_options(options)
    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), options[:key] || @hmac[:key], data)
  end
  
  def transformations
    trfms = {
      background: 'B',
      crop: 'C',
      expires: 'E',
      grayscale: 'G',
      interlace: 'I',
      lossless: 'L',
      optimize: 'O',
      padding: 'P',
      resize: 'S',
      watermark: 'W'
    }
    @plugins.values.find do |plugin|
      trfms = trfms.merge(plugin.transformations)
    end
    trfms
  end

  def encode_transformations(options = {})
    string = []
    options.each do |key, value|
      case key
      when :background
        string << 'B' + value.downcase
      when :crop
        string << 'C' + value.downcase
      when :expires
        string << 'E' + value.to_i.to_s(16)
      when :grayscale
        string << 'G'
      when :interlace
        string << 'I'
      when :lossless
        string << 'L'
      when :optimize
        string << 'O'
      when :padding
        string << if value.is_a?(Array)
          'P' + value.join(',')
        else
          'P' + value
        end
      when :resize
        string << 'S' + value.downcase
      when :transparent
        string << 'T'
      when :watermark
        if value.is_a?(Integer)
          string << 'W' + value.to_s + 'se'
        elsif value.is_a?(Hash)
          string << 'W' + (value[:id] || 0).to_s + (value[:position] || 'se') + value[:offset].to_s
        elsif value.is_a?(String)
          string << 'W' + value
        elsif value
          string << 'W0se'
        end
      # when :quality
      #   string << "Q#{value}"
      else
        @plugins.values.find do |plugin|
          if encode = plugin.encode_transformation(key, value)
            string << encode
            true
          end
        end
      end
    end
    
    string.join('')
  end
  
  # Delegates all uncauge class method calls to the singleton
  def self.method_missing(method, *args, &block)
    instance.__send__(method, *args, &block)
  end
end

require 'bob_ross/railtie' if defined?(Rails)
require 'rubygems'
require 'fileutils'
require 'open-uri'
require 'nokogiri'
require 'json'
require 'uri'
require 'time'
require 'yaml'
require 'i18n'
require 'kramdown'
require 'tumblr_client'
require 'mini_exiftool'

# On older Windows ruby versions this might be needed
#require 'openssl'
#OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

I18n.config.enforce_available_locales = false

module Importer
  class Tumblr
    def self.process(options)
      @url             = options.fetch(:url)
      @grab_images     = options.fetch(:grab_images, false)
      @auto_tags       = options.fetch(:auto_tags, false)
      @remove_gps_data = options.fetch(:remove_gps_data, false)

      client = ::Tumblr::Client.new

      per_page = 50
      posts = []
      # Two passes are required so that we can rewrite URLs.
      # First pass builds up an array of each post as a hash.
      begin
        current_page = (current_page || -1) + 1

        blog = client.posts(@url, reblog_info: true, limit: per_page, offset: current_page*per_page)

        @username = blog["blog"]["name"]

        puts "Page: #{current_page + 1} - Posts: #{blog["posts"].size}"
        batch = blog["posts"].map { |post| post_to_hash(post) }

        batch.each {|post| write_post(post)}

      end until blog["posts"].size < per_page
    end

    private

    # Writes a post out to disk
    def self.write_post(post)
      content = post[:content]

      c = Kramdown::Document.new(content, input: 'html').to_kramdown
      FileUtils.mkdir_p "_posts/tumblr/#{post[:date]}"
      File.open("_posts/tumblr/#{post[:date]}/#{post[:date]}-#{post[:id]}-#{post[:name]}.md", "w") do |f|
        f.puts post[:header].to_yaml + "---\n" + c
      end
    end

    # Converts each type of Tumblr post to a hash with all required
    # data for Jekyll.
    def self.post_to_hash(post)
      @id = post['id']

      meta = {}
      meta['tumblr_id'] = post['id']
      meta['tumblr_url'] = post["post_url"]
      meta['tumblr_type'] = post['type']

      meta['source_title'] = post["source_title"]
      meta['source_url'] = post['source_url']

      meta['reblogged_from_id'] = post['reblogged_from_id']
      meta['reblogged_from_url'] = post['reblogged_from_url']
      meta['reblogged_from_name'] = post['reblogged_from_name']

      meta['reblogged_root_id'] = post['reblogged_root_id']
      meta['reblogged_root_url'] = post['reblogged_root_url']
      meta['reblogged_root_name'] = post['reblogged_root_name']

      content = ""

      title = post['title'] || ""
      title = post['summary'] || "" if title.empty?
      title = post['source_title'] || "" if title.empty?
      title = post['source_url'] || "" if title.empty?
      title = "#{post['type'].capitalize} #{post['id']}" if title.empty?

      case post['type']
        when "text"
          # nothing to do
        when "link"
          meta['source_author'] = post["link_author"]
          meta['source_publisher'] = post['publisher']

          title = post["title"] || post["url"] || title

          content << "<p><a class=\"main_link\" href=\"#{post["url"]}\">#{title}</a></p>"

          if post["photos"]
            content << fetch_photos(post)
          end

          if post["excerpt"] && post["excerpt"] != ""
            content << "<blockquote class=\"excerpt\">#{post['excerpt']}</blockquote>"
          end
        when "photo"
          meta['photoset_layout'] = post['photoset_layout']
          if post["photos"]
            content << fetch_photos(post)
          end
        when "audio"
          meta['audio_provider'] = post['provider_url']
          meta['audio_artist'] = post['artist']
          meta['audio_album'] = post['album']
          meta['audio_type'] = post['audio_type']
          meta['audio_track'] = post['track_name']

          t = [post['artist'],post['track_name'],post['album']].compact.join(" - ")
          title = t if t!=''

          content << "<p class=\"album_art\"><img src=\"#{post['album_art']}\"></p>" if post['album_art']
          content << post["embed"]
        when "quote"
          content << "<blockquote class=\"quote\">#{post["text"]}</blockquote>#{post['source']}"
        when "chat"
          content = "<p class=\"dialogue\">"
          post["dialogue"].each do |line|
            content << "<strong>#{line['label']}</strong> #{line['phrase']}<br/>"
          end
          content << "</p>"
        when "video"
          player = post['player'].sort{|a,b|b['width'] <=> a['width']}.first['embed_code'].to_s

          if @grab_images
            doc = Nokogiri::HTML.fragment(player)

            begin
              first_trail = post['trail'].first
              trail_user = first_trail['blog']['name'] unless first_trail.nil?
              poster_user = post['reblogged_root_name'] || trail_user || post['blog_name']

              doc.css("source").each do |el|
                el.attributes['src'].value = save_photo(el.attributes['src'].value, poster_user)
              end

              doc.css("video").each do |el|
                el.attributes['poster'].value = save_photo(el.attributes['poster'].value, poster_user)
              end
            rescue OpenURI::HTTPError => err
              puts "WARNING! Failed to grab video #{player}"
            end

            player = doc.to_html
          end

          content << player
        when "answer"
          meta['asking_name'] = post['asking_name']
          meta['asking_url'] = post['asking_url']
          title = post["question"]
      end

      tags = post["tags"] || []

      content_data = generate_content(post)
      content << content_data[:content]
      if @auto_tags
        modified = false
        if @auto_tags[:text] && @auto_tags[:text_length]
          if content_data[:own_text_length] >= @auto_tags[:text_length]
            if !tags.include?(@auto_tags[:text])
              modified = true
              tags << @auto_tags[:text]
            end
          end
        end
        if @auto_tags[:own] || @auto_tags[:post]
          if !post['reblogged_root_name']
            # sometimes reblogged posts don't contain the root name, so we had to check for different options.
            # In this case we check if there is a trail, it has a maximum of one element, and that one element is own the owner's name
            if !post['trail'] || post['trail'].length==0 || (post['trail'].length == 1 && post['trail'].first['blog']['name'] == @username)
              if !tags.include?(@auto_tags[:post])
                tags << @auto_tags[:post]
                modified = true
              end
              # some logic to determine if it was probably original content or not
              if !post['source_url'] && !post['type'] == 'link' && (!post['type'] == 'video' || post['video_type'] == 'tumblr')
                if !tags.include?(@auto_tags[:own])
                  tags << @auto_tags[:own]
                  modified = true
                end
              end
            end
          end
        end

        if modified && @auto_tags[:update]
          tags.uniq!
          tag_string = tags.join(",")
          puts "Updating #{post['id']} with tags: #{tag_string}"
          client = ::Tumblr::Client.new

          p   client.edit(@url, id: post['id'], tags: tag_string)
        end
      end

      # clean up classes and figure tags without captions
      doc = Nokogiri::HTML.fragment(content)

      doc.css("*").remove_attr('style')
      doc.css("figure").each do |n|
        if n.children.count == 1
          n.replace(n.children.first)
        end
      end

      content = doc.to_html

      date = Date.parse(post['date']).to_s
      title = Nokogiri::HTML(title).text
      slug = if post["slug"] && post["slug"].strip != ""
        post["slug"]
      elsif title && title.downcase.gsub(/[^a-z0-9\-]/, '') != '' && title != 'no title'
        slug = title.downcase.strip.gsub(' ', '-').gsub(/[^a-z0-9\-]/, '')
        slug.length > 200 ? slug.slice(0..200) : slug
      else
        slug = post['id'].to_s
      end
      slug = I18n.transliterate(slug, replacement: '-')
      meta = meta.select { |_, v| !v.nil? }
      {
        :name => slug,
        :id => post['id'],
        :date => date,
        :header => {
          "layout" => "post",
          "title" => title,
          "date" => Time.at(post['timestamp']).xmlschema,
          "tags" => tags
        }.merge(meta),
        :content => content,
        :url => post["url"],
        :slug => post["url-with-slug"]
      }
    end

    def self.generate_content(post)
      response = {
        content: '',
        own_text_length: 0
      }

      if post['trail']
        trails = post['trail']
        response[:content] = trails.map do |trail|
          d = ""
          not_last = (trail != trails.last || trail['blog']['name'] != @username)
          if not_last
            d << "<blockquote class=\"trail\" data-id=\"#{trail['post']['id']}\" data-blog=\"#{trail['blog']['name']}\">"
          end
          cont = trail['content_raw']
          cont.gsub!(/\[\[MORE\]\]/,"")
          if @grab_images
            doc = Nokogiri::HTML.fragment(cont)

            doc.css("img").each do |el|
              begin
                el.attributes['src'].value = save_photo(el.attributes['src'].value, trail['blog']['name'])
              rescue
                puts "WARNING! Failed to grab photo #{el.attributes['src'].value}"
              end
            end

            cont = doc.to_html
          end
          response[:own_text_length] = cont.length if !not_last
          d << cont
          if not_last
            d << "</blockquote>"
          end
          d
        end.join("")
      end
      response
    end

    def self.fetch_photos(post)
      first_trail = post['trail'].first
      trail_user = first_trail['blog']['name'] unless first_trail.nil?

      post["photos"].map{|p| fetch_photo(p, post['reblogged_root_name'] || trail_user || post['blog_name'])}.join("")
    end

    def self.fetch_photo(photo, user)
      sizes = photo["alt_sizes"]
      sizes << photo['original_size'] if photo['original_size']
      return "" if sizes.nil?
      sizes.sort! {|a,b| b["width"] <=> a["width"]}

      sizes.each do |size|
        url = size["url"]
        next if url.nil?
        begin
          img = "<img alt=\"#{photo["caption"]}\" src=\"#{save_photo(url, user)}\"/>"
          if photo['caption'] && photo['caption'] != ""
            return "<p><figure>#{img}<figcaption>#{photo['caption']}</figcaption></figure></p>"
          else
            return "<p>#{img}</p>"
          end
        rescue OpenURI::HTTPError => err
          puts "Failed to grab photo"
        end
      end

      abort "Failed to fetch photo for post #{photo.inspect}"
    end

    def self.save_photo(url, user)
      if @grab_images && (user == @username || @grab_images == :all)
        tumblr_image = false
        if url =~ /tumblr.com/
          fragments = url.split('/')
          name = ""
          name << fragments.pop while name.length<8
          path = "tumblr_files/#{name}"
          tumblr_image = true
        else
          name = url.gsub(/[^a-zA-Z0-9._-]/,'_')
          path = "tumblr_files/external/#{name}"
        end
        FileUtils.mkdir_p "tumblr_files/external"

        # Don't fetch if we've already cached this file
        unless File.size? path
          puts "Fetching photo #{url}"
          File.open(path, "wb") { |f| f.write(open(url).read) }

          if @remove_gps_data
            photo = MiniExiftool.new(path)
            if photo['GPSLatitude'] || photo['GPSLongitude']
              photo.numerical = true
              photo.reload
              puts "GPS information found in #{path} ID #{@id}, removing"

              if photo['GPSLatitude'] && photo['GPSLatitude'] >= 51.41 && photo['GPSLatitude'] <= 51.42
                puts "WARNING LATITUDE MATCH"
              end

              if photo['GPSLongitude'] && photo['GPSLongitude'] >= 0.02 && photo['GPSLongitude'] <= 0.04
                puts "WARNING LONGITUDE MATCH"
              end
              system("exiftool","-gps:all=","-xmp:geotag=","-overwrite_original",path)
            end

          end
        end
        url = "/" + path
      end
      url
    end
  end
end

Tumblr.configure do |config|
  config.consumer_key = 'iXDtDNmr4jNfRDHst8uMLyIHUMgYIvNFeI7xLYUHoQf30bEA8m'
  config.consumer_secret = ''
  config.oauth_token = ''
  config.oauth_token_secret = ''
end

Importer::Tumblr.process({
  url: 'tumblr.sztupy.hu',
  grab_images: true,
  auto_tags: {
    own: 'own',
    post: 'post',
    text: 'rant',
    text_length: 512,
    update: true
  },
  remove_gps_data: false
})

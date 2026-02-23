require 'sinatra'
require 'google_search_results'
require 'down'
require 'fastimage'
require 'json'
require 'base64'
require 'httparty'
require 'nokogiri'
require 'time'
require 'uri'
require 'timeout'

# --- CONFIGURATION ---
GEMINI_API_KEY     = ENV['GEMINI_API_KEY']
SERPAPI_KEY        = ENV['SERPAPI_KEY']
EAN_SEARCH_TOKEN   = ENV['EAN_SEARCH_TOKEN']
ZENROWS_API_KEY    = ENV['ZENROWS_API_KEY']

BAD_URL_PATTERNS = %w[rezept recipe kuchen torta blog forum pinterest wiki tiktok facebook instagram].freeze
ALLOWED_KEYS = %w[
  brand product_name net_weight ingredients allergens may_contain nutri_scope
  energy fat saturates carbs sugars protein fiber salt organic_id sources_summary
].freeze

class MasterDataHunter
  include HTTParty

  def initialize
    @headers = { 'Content-Type' => 'application/json' }
    
    # 1. Market Language Logic (For Gemini AI Prompt)
    @country_langs = {
      "DE" => "German", "AT" => "German", "CH" => "German",
      "UK" => "English", "GB" => "English", "FR" => "French",
      "IT" => "Italian", "ES" => "Spanish", "NL" => "Dutch",
      "DK" => "Danish", "SE" => "Swedish", "NO" => "Norwegian",
      "PL" => "Polish", "PT" => "Portuguese", "FI" => "Finnish",
      "BE" => "German, French, AND Dutch (Must provide all 3)"
    }

    # 2. Google HL Codes (2-letter codes for SerpAPI Image Search)
    @hl_codes = {
      "DE" => "de", "AT" => "de", "CH" => "de", "UK" => "en", "GB" => "en",
      "FR" => "fr", "IT" => "it", "ES" => "es", "NL" => "nl", "BE" => "nl",
      "DK" => "da", "SE" => "sv", "NO" => "no", "PL" => "pl", "PT" => "pt", "FI" => "fi"
    }

    # 3. Localized Deep Search Terms
    @local_search_terms = {
      "FR" => "ingrédients nutrition", "IT" => "ingredienti nutrizionali", "ES" => "ingredientes nutrición",
      "NL" => "ingrediënten voedingswaarde", "DK" => "ingredienser næringsindhold", "SE" => "ingredienser näringsvärde",
      "NO" => "ingredienser næringsinnhold", "FI" => "ainesosat ravintosisältö", "PL" => "składniki wartości odżywcze",
      "DE" => "zutaten nährwerte", "AT" => "zutaten nährwerte", "CH" => "zutaten nährwerte",
      "BE" => "ingrédients ingrediënten", "UK" => "ingredients nutrition", "PT" => "ingredientes nutrição"
    }

    # 4. Country Names for Strict Image Hunting
    @country_names = {
      "DE" => "Deutschland Germany", "AT" => "Österreich Austria", "CH" => "Schweiz Switzerland",
      "UK" => "UK United Kingdom",   "GB" => "UK United Kingdom", "FR" => "France",
      "IT" => "Italia Italy", "ES" => "España Spain", "PL" => "Polska Poland",
      "DK" => "Danmark Denmark", "NL" => "Nederland Netherlands", "BE" => "Belgique België Belgium",
      "SE" => "Sverige Sweden", "NO" => "Norge Norway", "PT" => "Portugal", "FI" => "Suomi Finland"
    }

    # 5. Trusted Retailers
    @goldmine_sites = {
      "FR" => "site:carrefour.fr OR site:auchan.fr OR site:coursesu.com OR site:openfoodfacts.org",
      "UK" => "site:tesco.com OR site:sainsburys.co.uk OR site:asda.com OR site:ocado.com",
      "NL" => "site:ah.nl OR site:jumbo.com OR site:plus.nl",
      "BE" => "site:delhaize.be OR site:colruyt.be OR site:carrefour.be",
      "DE" => "site:rewe.de OR site:edeka.de OR site:kaufland.de OR site:motatos.de OR site:picnic.app OR site:dm.de OR site:rossmann.de",
      "AT" => "site:billa.at OR site:spar.at OR site:gurkerl.at OR site:motatos.at OR site:hofer.at OR site:unimarkt.at",
      "DK" => "site:nemlig.com OR site:matsmart.dk OR site:rema1000.dk OR site:netto.dk",
      "IT" => "site:carrefour.it OR site:conad.it OR site:coop.it",
      "ES" => "site:carrefour.es OR site:mercadona.es OR site:dia.es",
      "SE" => "site:ica.se OR site:coop.se OR site:willys.se OR site:matsmart.se",
      "NO" => "site:oda.com OR site:meny.no OR site:holdbart.no",
      "FI" => "site:k-ruoka.fi OR site:s-kaupat.fi OR site:matsmart.fi",
      "PL" => "site:carrefour.pl OR site:auchan.pl OR site:frisco.pl"
    }
  end

  def process_product(gtin, market)
    return { found: false, status: "Missing GEMINI_API_KEY" } if GEMINI_API_KEY.nil? || GEMINI_API_KEY.empty?

    confirmed_sources = []
    is_deep_search = false
    
    # --- STEP 1: OFFICIAL REGISTRY ---
    official_data = fetch_official_ean_data(gtin)
    registry_name = official_data ? official_data['name'] : nil
    if official_data
      confirmed_sources << { type: "registry", title: "Official Registry", url: "https://www.ean-search.org/?q=#{gtin}" }
    end

    # --- STEP 2: PARALLEL SEARCH EXECUTION ---
    threads = []
    
    retailer_results = []
    threads << Thread.new { retailer_results = find_retailer_urls(gtin, market) }

    deep_results = []
    threads << Thread.new do
      search_name = registry_name || infer_name_from_ean(gtin, market)
      deep_results = find_deep_urls(search_name, market) if search_name
    end

    image_data = nil
    image_thread = Thread.new { image_data = find_best_image(gtin, market, official_data) }

    # Thread Synchronization Guard
    deadline = Time.now + 25
    image_thread.join([deadline - Time.now, 0].max) if image_thread.alive?
    threads.each do |t|
      remaining = deadline - Time.now
      t.join(remaining > 0 ? remaining : 0.1)
    end
    (threads + [image_thread]).each { |t| t.kill if t.alive? }

    all_urls = (retailer_results + deep_results).uniq.first(10)

    # --- STEP 3: SCRAPING ---
    web_data = fetch_parallel_page_data(all_urls)
    web_data[:valid_urls].each { |u| confirmed_sources << { type: "web", title: host_from_url(u), url: u } }
    
    if image_data
      confirmed_sources << { type: "image", title: "Source Image", url: image_data[:url] }
    end

    if (image_data.nil? || image_data[:base64].nil?) && web_data[:text].strip.empty?
      return empty_result(gtin, market, "No Data Found (Blind)", nil)
    end

    final_name_context = official_data ? official_data : { 'name' => registry_name }

    # --- STEP 4: AI ANALYSIS ---
    ai_result = analyze_with_gemini(image_data, web_data[:text], final_name_context, gtin, market)
    
    ai_hash = {}
    if ai_result.is_a?(Hash)
      ALLOWED_KEYS.each { |k| ai_hash[k] = ai_result[k] if ai_result.key?(k) }
      ai_hash["error"] = ai_result["error"] if ai_result["error"]
    end

    if ai_hash["error"]
      return empty_result(gtin, market, ai_hash["error"], image_data ? image_data[:url] : nil)
    end

    # --- STEP 5: LOCALIZED FALLBACK ESCALATION ---
    ing_text = ai_hash["ingredients"].to_s.downcase
    missing_phrases = [
      "keine", "not found", "unavailable", "inconnu", "non trouvé", "nicht verfügbar", "none",
      "no encontrado", "no disponible", "niet gevonden", "niet beschikbaar", 
      "ikke fundet", "hittades inte", "ikke funnet", "brak", "niedostępne", 
      "ei löydy", "non trovato", "non disponibile"
    ]
    
    if ing_text.length < 10 || missing_phrases.any? { |p| ing_text.include?(p) }
      log("Fallback Escalation triggered for #{gtin}: Missing/poor ingredients.")
      
      search_name = ai_hash["product_name"] || registry_name || infer_name_from_ean(gtin, market)
      
      if search_name && search_name.length > 3
        fallback_urls = find_deep_urls(search_name, market) 
        
        if fallback_urls.any?
          fallback_web_data = fetch_parallel_page_data(fallback_urls)
          
          if fallback_web_data[:text].length > 200
            is_deep_search = true
            combined_text = web_data[:text] + "\n\n=== FALLBACK NAME SEARCH DATA ===\n" + fallback_web_data[:text]
            fallback_web_data[:valid_urls].each { |u| confirmed_sources << { type: "rescue", title: host_from_url(u), url: u } }
            
            ai_result2 = analyze_with_gemini(image_data, combined_text, final_name_context, gtin, market)
            if ai_result2.is_a?(Hash) && !ai_result2["error"]
              ALLOWED_KEYS.each { |k| ai_hash[k] = ai_result2[k] if ai_result2.key?(k) }
            end
            
            web_data[:valid_urls] += fallback_web_data[:valid_urls]
            web_data[:text] = combined_text
          end
        end
      end
    end

    origin_country = official_data ? official_data['issuingCountry'] : nil
    display_image = if image_data && image_data[:base64] && image_data[:mime]
                      "data:#{image_data[:mime]};base64,#{image_data[:base64]}"
                    else
                      image_data ? image_data[:url] : nil
                    end

    has_registry = !!official_data
    has_image = image_data && image_data[:base64]
    has_web = web_data[:valid_urls].any? && web_data[:text].length > 200

    computed_status = if is_deep_search
                        "Found (Deep Search)"
                      elsif has_registry && has_web && has_image
                        "Found (Registry+Web+Image)"
                      elsif has_web && has_image
                        "Found (Web+Image)"
                      elsif has_web
                        "Found (Web)"
                      elsif has_image && has_registry
                        "Found (Registry+Image)"
                      elsif has_image
                        "Found (Image)"
                      elsif has_registry
                        "Registry Only"
                      else
                        "Blind"
                      end

    {
      found: true,
      gtin: gtin,
      status: computed_status,
      market: market,
      image_url: display_image, 
      issuing_country: origin_country,
      defined_sources: confirmed_sources.uniq { |s| s[:url] }
    }.merge(ai_hash)
  end

  private

  def log(msg)
    STDERR.puts("[#{Time.now.utc.iso8601}] #{msg}")
  end

  def host_from_url(url)
    URI.parse(url).host.sub(/^www\./, '') rescue "Link"
  end

  def mime_from_fastimage(type)
    case type
    # --- The Golden Trio (Perfect for both Browser & Gemini) ---
    when :jpeg, :jpg then "image/jpeg"
    when :png  then "image/png"
    when :webp then "image/webp"
    
    # --- The Apple Formats (Great for Gemini, but browsers might show a broken icon) ---
    when :heic then "image/heic"
    when :heif then "image/heif"

    # --- The Modern Web Formats (Great for Browsers, Gemini *usually* processes them or ignores gracefully) ---
    when :avif then "image/avif"
    when :bmp  then "image/bmp"
    when :gif  then "image/gif"
    
    else nil
    end
  end

  def is_clean_url?(url)
    return false if url.nil?
    !BAD_URL_PATTERNS.any? { |p| url.downcase.include?(p) }
  end

  def infer_name_from_ean(gtin, market)
    return nil if SERPAPI_KEY.nil?
    gl = (market == "UK" ? "gb" : market.downcase)
    begin
      res = Timeout.timeout(15) { GoogleSearch.new(q: "#{gtin}", gl: gl, num: 2, api_key: SERPAPI_KEY).get_hash }
      first_result = (res[:organic_results] || []).first
      return first_result[:title].split(/ [|-] /).first.strip if first_result
    rescue => e
      log("Search API error (name inference): #{e.message}")
    end
    nil
  end

  def find_retailer_urls(gtin, market)
    return [] if SERPAPI_KEY.nil?
    gl = (market == "UK" ? "gb" : market.downcase)
    goldmine = @goldmine_sites[market]
    bans = "-site:openfoodfacts.org"
    return [] unless goldmine
    
    urls = []
    begin
      res = Timeout.timeout(15) { GoogleSearch.new(q: "#{goldmine} #{gtin} #{bans}", gl: gl, num: 7, api_key: SERPAPI_KEY).get_hash }
      (res[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
    rescue => e
      log("Search API error (retailers): #{e.message}")
    end
    urls
  end

  def find_deep_urls(name, market)
    return [] if name.nil? || name.length < 3
    gl = (market == "UK" ? "gb" : market.downcase)
    
    # Keeping the social media bans to keep SEO junk out
    bans = "-site:openfoodfacts.org -site:pinterest.* -site:tiktok.com -site:facebook.com -site:instagram.com"
    
    # 1. Clean the name
    clean_name = name.gsub(/[^a-zA-Z0-9\s]/, '').gsub(/\s+/, ' ').strip
    
    # 2. Smart Truncation: Grab only the first 4 words
    short_name = clean_name.split(' ')[0..3].join(" ")
    
    goldmine = @goldmine_sites[market]
    local_terms = @local_search_terms[market] || "ingredients nutrition"
    
    urls = []
    begin
      # Stage 1: Trusted Local Domains (Using short_name!)
      if goldmine
        res = Timeout.timeout(15) { GoogleSearch.new(q: "#{goldmine} #{short_name} #{local_terms} #{bans}", gl: gl, num: 6, api_key: SERPAPI_KEY).get_hash }
        (res[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
      end

      # Stage 2: Broad Local Search (Using short_name!)
      if urls.empty?
        res = Timeout.timeout(15) { GoogleSearch.new(q: "#{short_name} #{local_terms} #{bans}", gl: gl, num: 6, api_key: SERPAPI_KEY).get_hash }
        (res[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
      end
      
      # --- NEW: STAGE 3 (THE GLOBAL BYPASS) ---
      if urls.empty?
        # Logging short_name so you can verify it in Render logs
        log("Global Bypass Triggered for: #{short_name}") 
        
        # Clean query using short_name, NO stray quotes, and num: 6
        global_res = Timeout.timeout(15) { GoogleSearch.new(q: "#{short_name} ingredients nutrition #{bans}", num: 6, api_key: SERPAPI_KEY).get_hash }
        (global_res[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
      end

    rescue => e
      log("Search API error (deep links): #{e.message}")
    end
    urls.uniq.first(6)
  end

  # --- ULTIMATE 5-TIER IMAGE DOWNLOADER ---
  def find_best_image(gtin, market, official_data)
    return nil if SERPAPI_KEY.nil? || SERPAPI_KEY.empty?
    gl = (market == "UK" ? "gb" : market.downcase)
    
    # FIX: Use the new 2-letter code dictionary specifically for the hl parameter
    hl = @hl_codes[market] || "en" 
    
    country_name = @country_names[market] || ""

    if official_data && is_good_image_size?(official_data['image'])
      log("IMG found in Official Registry for #{gtin}")
      encoded = download_and_encode(official_data['image'], "https://www.ean-search.org/?q=#{gtin}")
      return encoded if encoded
    end

    searches = [
      "site:barcodelookup.com OR site:go-upc.com \"#{gtin}\"",
      "\"#{gtin}\" #{country_name}",
      "\"#{gtin}\""
    ]
    
    if official_data && official_data['name']
      clean_name = official_data['name'].gsub(/[^a-zA-Z0-9\s]/, '')
      searches << clean_name if clean_name.length > 3
    end

    searches.each_with_index do |query, index|
      begin
        res = Timeout.timeout(10) { GoogleSearch.new(q: query, tbm: "isch", gl: gl, hl: hl, api_key: SERPAPI_KEY).get_hash }
        images = (res[:images_results] || []).first(10)
        
        images.each do |img|
          url = img[:original]
          next if url.nil? || url.include?("placeholder")
          next if url.include?("pinterest") || url.include?("ebay") || url.include?("openfoodfacts")
          
          if is_good_image_size?(url)
            encoded = download_and_encode(url, img[:link])
            if encoded
              log("IMG success=true on attempt #{index+2} for #{url}")
              return encoded
            end
          end
        end
      rescue => e
        log("IMG SerpAPI fail on query '#{query}': #{e.message}")
      end
    end
    nil
  end

  def is_good_image_size?(url)
    return false if url.nil? || url.empty?
    begin
      size = Timeout.timeout(4) { FastImage.size(url, timeout: 3, http_header: { 'User-Agent' => 'Mozilla/5.0' }) }
      return false unless size
      w, h = size
      w > 300 && (w.to_f / h.to_f).between?(0.3, 2.5)
    rescue
      false
    end
  end

  def download_and_encode(url, source_link)
    tempfile = Down.download(
      url, 
      max_size: 1.5 * 1024 * 1024,
      open_timeout: 4, 
      read_timeout: 4, 
      headers: { 
        "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36",
        "Accept" => "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        "Referer" => (source_link || "https://www.google.com/")
      }
    )
    
    type = FastImage.type(tempfile.path)
    mime = mime_from_fastimage(type)
    
    unless mime
      log("IMG skip url=#{url} reason=Not an image block (type: #{type.inspect})")
      return nil
    end

    base64 = Base64.strict_encode64(File.binread(tempfile.path))
    { url: url, source: source_link, base64: base64, mime: mime }
  rescue => e
    log("IMG download fail url=#{url} err=#{e.class}: #{e.message}")
    nil
  end

  def fetch_parallel_page_data(urls)
    return { text: "", valid_urls: [] } if urls.empty?

    threads = []
    results_text = []
    valid_urls = []
    
    urls.each do |url|
      threads << Thread.new do
        begin
          response = nil
          
          # If ZenRows is configured, use it to smash through Cloudflare
          if ZENROWS_API_KEY && !ZENROWS_API_KEY.empty?
            api_url = "https://api.zenrows.com/v1/"
            query_params = {
              apikey: ZENROWS_API_KEY,
              url: url,
              js_render: 'true', # Renders JavaScript (great for modern stores)
              antibot: 'true'    # Bypasses Cloudflare / Datadome 
            }
            # ZenRows needs extra time to solve Cloudflare CAPTCHAs, so we give it 25 seconds
            response = HTTParty.get(api_url, query: query_params, timeout: 25)
          else
            # Fallback to standard scraping if ZenRows key is missing
            agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
            response = HTTParty.get(url, headers: { "User-Agent" => agent }, timeout: 10)
          end
          
          if response.code == 200
            doc = Nokogiri::HTML(response.body)
            doc.css('script, style, nav, footer, iframe, header, .cookie').remove
            txt = doc.text.gsub(/\s+/, " ").strip[0..8000]
            
            json_ld = ""
            doc.css('script[type="application/ld+json"]').each { |s| json_ld += s.content.to_s.gsub(/\s+/, " ").strip[0..3000] + " " }
            
            doc = nil 
            
            # Keep the site if it has visible text OR rich hidden JSON data
            if txt.length > 150 || json_ld.length > 100
              Thread.current[:valid] = url
              Thread.current[:text] = "=== SOURCE: #{url} ===\nCONTENT: #{txt}\nJSON-LD: #{json_ld}\n\n"
            end
          else
             log("Scrape non-200 url=#{url} status=#{response.code}")
          end
        rescue => e
          log("Scrape fail url=#{url} err=#{e.class}: #{e.message}")
        end 
      end
    end

    threads.each(&:join)

    threads.each do |t| 
      if t[:valid]
        valid_urls << t[:valid]
        results_text << t[:text]
      end
    end
    
    { text: results_text.join("\n"), valid_urls: valid_urls }
  end

  def fetch_official_ean_data(gtin)
    return nil if EAN_SEARCH_TOKEN.nil? || EAN_SEARCH_TOKEN.empty?
    begin
      url = "https://api.ean-search.org/api?token=#{EAN_SEARCH_TOKEN}&op=barcode-lookup&format=json&ean=#{gtin}"
      resp = HTTParty.get(url, timeout: 4)
      return JSON.parse(resp.body).first if resp.code == 200
    rescue => e
      log("EAN API error: #{e.message}")
    end
    nil
  end

  def analyze_with_gemini(image_data, text_data, official, gtin, market)
    target_lang = @country_langs[market] || "English"
    name_info = official ? official['name'] : (official.is_a?(Hash) ? official['name'] : "Unknown")
    official_txt = "PRODUCT IDENTITY: #{name_info}"

    prompt = <<~TEXT
      You are a Food Data Expert.
      #{official_txt}
      
      INPUT DATA:
      #{text_data}
      #{image_data && image_data[:base64] ? "IMAGE: Provided" : "IMAGE: Not Available"}

      MARKET REQUIREMENTS:
      - Target Market: #{market}
      - Target Languages: #{target_lang}
      
      TASK:
      1. Synthesize all data.
      2. **Translation:** Translate Name, Ingredients, and Allergens to **#{target_lang}**.
      3. **BE Specific:** If Market is 'BE', output Ingredients/Allergens in German, French, AND Dutch.
      4. **Nutrition:** Extract 100g/ml values.
      
      OUTPUT JSON (Strict Schema):
      {
        "brand": "Brand Name",
        "product_name": "Name (Translated)", 
        "net_weight": "Value",
        "ingredients": "List (Translated)", 
        "allergens": "List (Translated)",
        "may_contain": "List (Translated)",
        "nutri_scope": "100g", "energy": "kJ/kcal", "fat": "val", "saturates": "val",
        "carbs": "val", "sugars": "val", "protein": "val", "fiber": "val", "salt": "val",
        "organic_id": "Code", 
        "sources_summary": "Source description"
      }
    TEXT

    models = ["models/gemini-2.0-flash", "models/gemini-2.0-flash-lite", "models/gemini-1.5-flash"]
    parts = [{ text: prompt }]
    
    if image_data && image_data[:base64] && image_data[:mime]
      parts << { inline_data: { mime_type: image_data[:mime], data: image_data[:base64] } }
    end

    models.each do |m|
      url = "https://generativelanguage.googleapis.com/v1beta/#{m}:generateContent?key=#{GEMINI_API_KEY}"
      begin
        resp = HTTParty.post(url, body: { contents: [{ parts: parts }] }.to_json, headers: @headers, timeout: 35)
        if resp.code == 200
          raw = resp.dig("candidates", 0, "content", "parts", 0, "text")
          next unless raw
          return JSON.parse(raw.gsub(/```json|```/, "").strip)
        end
      rescue => e
        log("Gemini Model #{m} failed: #{e.message}")
        next 
      end
    end
    { "error" => "AI Failed to Analyze" }
  end

  def empty_result(gtin, market, msg, img)
    { found: false, status: msg, gtin: gtin, market: market, image_url: img, defined_sources: [] }
  end
end

# --- ROUTES ---

get '/' do
  erb :index
end

get '/api/search' do
  content_type :json
  begin
    hunter = MasterDataHunter.new
    result = hunter.process_product(params[:gtin], params[:market])
    result.to_json
  rescue => e
    STDERR.puts("[CRITICAL] Route Error: #{e.class} - #{e.message}\n#{e.backtrace.first(3).join("\n")}")
    { found: false, status: "Server Error", gtin: params[:gtin] }.to_json
  end
end

__END__

@@ index
<!DOCTYPE html>
<html>
<head>
  <title>TGTG AI Hunter v4.1 (Stable & Multilingual)</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f4f6f8; padding: 20px; color: #333; }
    .container { max-width: 98%; margin: 0 auto; background: white; padding: 25px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.08); }
    h1 { color: #00816A; margin-bottom: 20px; }
    
    .controls { display: flex; gap: 15px; margin-bottom: 20px; background: #eefcf9; padding: 20px; border-radius: 8px; border: 1px solid #ccece6; }
    textarea { width: 100%; height: 100px; padding: 12px; border: 1px solid #ddd; border-radius: 6px; font-family: monospace; font-size: 14px; }
    button { background: #00816A; color: white; border: none; padding: 12px 24px; border-radius: 6px; font-weight: 600; cursor: pointer; transition: background 0.2s; }
    button:hover { background: #006653; }
    button:disabled { background: #ccc; cursor: not-allowed; }

    .table-wrapper { overflow-x: auto; margin-top: 25px; border: 1px solid #e1e4e8; border-radius: 8px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; min-width: 3200px; } 
    th { text-align: left; background: #00816A; color: white; padding: 14px 12px; position: sticky; left: 0; z-index: 10; white-space: nowrap; font-weight: 600; letter-spacing: 0.5px; }
    td { padding: 12px; border-bottom: 1px solid #eee; vertical-align: top; max-width: 300px; line-height: 1.4; }
    tr:nth-child(even) { background: #f8f9fa; }
    tr:hover { background: #f1f3f5; }

    .status-badge { padding: 4px 8px; border-radius: 4px; font-weight: 600; font-size: 11px; text-transform: uppercase; }
    .st-found { background: #d4edda; color: #155724; }
    .st-deep { background: #cce5ff; color: #004085; }
    .st-reg { background: #fff3cd; color: #856404; }
    .st-miss { background: #f8d7da; color: #721c24; }
    .img-thumb { width: 50px; height: 50px; object-fit: contain; border: 1px solid #ddd; border-radius: 4px; background: white; padding: 2px; }

    .source-list { display: flex; flex-direction: column; gap: 4px; }
    .src-btn { 
      display: inline-flex; align-items: center; gap: 5px; 
      padding: 4px 8px; border-radius: 4px; font-size: 11px; text-decoration: none; 
      border: 1px solid #ced4da; background: #fff; color: #495057; transition: all 0.2s;
      width: fit-content;
    }
    .src-btn:hover { border-color: #00816A; color: #00816A; background: #f0fdf9; }
    .src-registry { border-left: 3px solid #00816A; }
    .src-web { border-left: 3px solid #007bff; }
    .src-rescue { border-left: 3px solid #dc3545; }
    .src-img { border-left: 3px solid #6f42c1; }
    .ai-note { font-size: 10px; color: #888; margin-bottom: 5px; font-style: italic; }
  </style>
</head>
<body>

<div class="container">
  <div style="display:flex; justify-content:space-between; align-items:center;">
    <h1>✨ TGTG AI Hunter <span style="font-size:0.5em; color:#666; font-weight:normal;">v4.1 (Stable & Multilingual)</span></h1>
    <span id="progressIndicator" style="font-weight:bold; color:#00816A;"></span>
  </div>

  <div class="controls">
    <div style="flex:1;">
      <label style="font-weight:bold; display:block; margin-bottom:5px;">Paste EANs (one per line):</label>
      <textarea id="inputList" placeholder="4018077669132..."></textarea>
    </div>
    <div style="width: 200px;">
       <label style="font-weight:bold; display:block; margin-bottom:5px;">Market:</label>
       <select id="marketSelect" style="width:100%; padding:10px; border-radius:6px; border:1px solid #ddd;">
        <option value="BE">Belgium (BE)</option>
        <option value="DK">Denmark (DK)</option>
        <option value="DE">Germany (DE)</option>
        <option value="AT">Austria (AT)</option>
        <option value="NL">Netherlands (NL)</option>
        <option value="FR">France (FR)</option>
        <option value="IT">Italy (IT)</option>
        <option value="ES">Spain (ES)</option>
        <option value="UK">United Kingdom (UK)</option>
        <option value="PL">Poland (PL)</option>
        <option value="SE">Sweden (SE)</option>
        <option value="NO">Norway (NO)</option>
        <option value="FI">Finland (FI)</option>
      </select>
      <button id="startBtn" onclick="startBatch()" style="width:100%; margin-top:10px;">🚀 Analyze</button>
      <button id="downloadBtn" onclick="downloadCSV()" style="width:100%; margin-top:5px; background:#343a40; display:none;">⬇️ CSV</button>
    </div>
  </div>

  <div class="table-wrapper">
    <table id="resultsTable">
      <thead>
        <tr>
          <th>Status</th>
          <th>Image</th>
          <th>EAN</th>
          <th>Brand</th>
          <th>Product Name</th>
          <th>Origin</th>
          <th>Sources</th>
          <th>Net Weight</th>
          <th>Organic ID</th>
          <th>Ingredients</th>
          <th>Allergens</th>
          <th>May Contain</th>
          <th>Nutri Scope</th>
          <th>Energy</th>
          <th>Fat</th>
          <th>Saturates</th>
          <th>Carbs</th>
          <th>Sugars</th>
          <th>Fiber</th>
          <th>Protein</th>
          <th>Salt</th>
        </tr>
      </thead>
      <tbody></tbody>
    </table>
  </div>
</div>

<script>
  let resultsData = [];

  async function startBatch() {
    const text = document.getElementById('inputList').value;
    const market = document.getElementById('marketSelect').value;
    const lines = text.split('\n').map(l => l.trim()).filter(l => l.length > 0);

    if (lines.length === 0) { alert("Please paste some EANs first."); return; }

    document.getElementById('startBtn').disabled = true;
    const tbody = document.querySelector('#resultsTable tbody');
    tbody.innerHTML = "";
    resultsData = [];

    let processed = 0;
    const updateProgress = () => { document.getElementById('progressIndicator').innerText = `Processing: ${processed}/${lines.length}`; };
    updateProgress();

    for (const gtin of lines) {
      const tr = document.createElement('tr');
      let emptyCells = ""; for(let i=0; i<19; i++) { emptyCells += "<td></td>"; }
      tr.innerHTML = `<td><span class="status-badge" style="background:#eee; color:#666;">...</span></td>` + emptyCells;
      tbody.appendChild(tr);

      try {
        const response = await fetch(`/api/search?gtin=${gtin}&market=${market}`);
        const data = await response.json();

        let sClass = 'st-found';
        if (data.status.includes("Registry")) sClass = 'st-reg';
        if (data.status.includes("Deep")) sClass = 'st-deep';
        if (data.status.includes("Error") || data.status.includes("Missing") || data.status.includes("Server") || data.status.includes("Blind")) sClass = 'st-miss';

        const imgHTML = data.image_url ? `<a href="${data.image_url}" target="_blank"><img src="${data.image_url}" class="img-thumb"></a>` : '-';

        let sourcesHTML = `<div class="source-list">`;
        if (data.sources_summary) sourcesHTML += `<span class="ai-note">${data.sources_summary}</span>`;
        if (data.defined_sources && data.defined_sources.length > 0) {
           data.defined_sources.forEach(src => {
              let icon = "🔗";
              let cssClass = "src-web";
              if(src.type === 'registry') { icon = "🏛️"; cssClass = "src-registry"; }
              if(src.type === 'image')    { icon = "📸"; cssClass = "src-img"; }
              if(src.type === 'rescue')   { icon = "🆘"; cssClass = "src-rescue"; }
              sourcesHTML += `<a href="${src.url}" target="_blank" class="src-btn ${cssClass}">${icon} ${src.title}</a>`;
           });
        } else {
           sourcesHTML += `<span style="font-size:11px; color:#999;">No links</span>`;
        }
        sourcesHTML += `</div>`;
        
        const fmt = (val) => {
          if (!val) return "-";
          if (Array.isArray(val)) val = val.join(', ');
          if (typeof val === 'object') val = JSON.stringify(val);
          return String(val).replace(/\n/g, "<br>");
        };

        tr.innerHTML = `
          <td><span class="status-badge ${sClass}">${data.status}</span></td>
          <td>${imgHTML}</td>
          <td>${gtin}</td>
          <td>${data.brand || '-'}</td>
          <td style="font-weight:bold;">${data.product_name || '-'}</td>
          <td style="text-align:center;">${data.issuing_country || '-'}</td>
          <td>${sourcesHTML}</td>
          <td>${data.net_weight || '-'}</td>
          <td>${data.organic_id || '-'}</td>
          <td style="font-size:11px;">${fmt(data.ingredients)}</td>
          <td style="font-size:11px;">${fmt(data.allergens)}</td>
          <td style="font-size:11px;">${fmt(data.may_contain)}</td>
          <td>${data.nutri_scope || '-'}</td>
          <td>${data.energy || '-'}</td>
          <td>${data.fat || '-'}</td>
          <td>${data.saturates || '-'}</td>
          <td>${data.carbs || '-'}</td>
          <td>${data.sugars || '-'}</td>
          <td>${data.fiber || '-'}</td>
          <td>${data.protein || '-'}</td>
          <td>${data.salt || '-'}</td>
        `;
        resultsData.push(data);
      } catch (e) {
        console.error(`Frontend crashed on EAN ${gtin}:`, e);
        tr.innerHTML = `<td colspan="20" style="color:red; text-align:center;">Network/Server Error for ${gtin}</td>`;
      }
      processed++;
      updateProgress();
    }
    
    document.getElementById('startBtn').disabled = false;
    document.getElementById('downloadBtn').style.display = "block";
    document.getElementById('progressIndicator').innerText = "✅ Complete";
  }

  function downloadCSV() {
    let csv = "Status,EAN,Brand,ProductName,Origin,Sources,NetWeight,OrganicID,Ingredients,Allergens,MayContain,NutriScope,Energy,Fat,Saturates,Carbs,Sugars,Fiber,Protein,Salt\n";
    resultsData.forEach(row => {
      const clean = (txt) => (txt || "-").toString().replace(/,/g, " ").replace(/\n/g, " | ").trim();
      
      let srcList = "";
      if(row.defined_sources) {
         srcList = row.defined_sources.map(s => `[${s.type.toUpperCase()}: ${s.url}]`).join(" | ");
      }

      csv += `${row.status},${row.gtin},${clean(row.brand)},${clean(row.product_name)},${clean(row.issuing_country)},` +
             `${srcList},${clean(row.net_weight)},${clean(row.organic_id)},` +
             `${clean(row.ingredients)},${clean(row.allergens)},${clean(row.may_contain)},` +
             `${clean(row.nutri_scope)},${clean(row.energy)},${clean(row.fat)},` +
             `${clean(row.saturates)},${clean(row.carbs)},${clean(row.sugars)},` +
             `${clean(row.fiber)},${clean(row.protein)},${clean(row.salt)}\n`;
    });
    
    const link = document.createElement("a");
    link.href = "data:text/csv;charset=utf-8," + encodeURI(csv);
    link.download = "tgtg_hunter_results.csv";
    link.click();
  }
</script>

</body>
</html>
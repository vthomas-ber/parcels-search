require 'sinatra'
require 'google_search_results'
require 'down'
require 'fastimage'
require 'json'
require 'base64'
require 'httparty'
require 'nokogiri'
require 'timeout'

# --- CONFIGURATION ---
GEMINI_API_KEY     = ENV['GEMINI_API_KEY']
SERPAPI_KEY        = ENV['SERPAPI_KEY']
EAN_SEARCH_TOKEN   = ENV['EAN_SEARCH_TOKEN']

class MasterDataHunter
  include HTTParty

  SUPPORTED_MARKETS = %w[BE DK DE AT NL FR IT ES UK PL SE NO FI].freeze

  def initialize
    @headers = { 'Content-Type' => 'application/json' }
    
    # 1. Market Language Logic
    @country_langs = {
      "DE" => "German", "AT" => "German", "CH" => "German",
      "UK" => "English", "GB" => "English", "FR" => "French",
      "IT" => "Italian", "ES" => "Spanish", "NL" => "Dutch",
      "DK" => "Danish", "SE" => "Swedish", "NO" => "Norwegian",
      "PL" => "Polish", "PT" => "Portuguese", "FI" => "Finnish",
      "BE" => "German, French, AND Dutch (Must provide all 3)"
    }

    # 2. THE GOLDMINE (Retailers)
    @goldmine_sites = {
      "FR" => "site:carrefour.fr OR site:auchan.fr OR site:coursesu.com OR site:openfoodfacts.org",
      "UK" => "site:tesco.com OR site:sainsburys.co.uk OR site:asda.com OR site:ocado.com",
      "NL" => "site:ah.nl OR site:jumbo.com OR site:plus.nl",
      "BE" => "site:delhaize.be OR site:colruyt.be OR site:carrefour.be",
      "DE" => "site:rewe.de OR site:edeka.de OR site:kaufland.de OR site:motatos.de OR site:picnic.app",
      "AT" => "site:billa.at OR site:spar.at OR site:gurkerl.at OR site:motatos.at",
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
    return { found: false, status: "Missing GTIN" } if gtin.to_s.strip.empty?
    return { found: false, status: "Unsupported market '#{market}'" } unless SUPPORTED_MARKETS.include?(market)
    return { found: false, status: "Missing GEMINI_API_KEY" } if GEMINI_API_KEY.nil? || GEMINI_API_KEY.empty?

    confirmed_sources = []
    
    # --- STEP 1: OFFICIAL REGISTRY (Fast) ---
    official_data = fetch_official_ean_data(gtin)
    registry_name = official_data ? official_data['name'] : nil
    if official_data
      confirmed_sources << { type: "registry", title: "Official Registry", url: "https://www.ean-search.org/?q=#{gtin}" }
    end

    # --- STEP 2: PARALLEL SEARCH EXECUTION ---
    # We run 3 tasks at the exact same time:
    # 1. Retailer Search (Goldmine)
    # 2. Deep Search (Name + Ingredients)
    # 3. Image Search
    
    threads = []
    
    # Task A: Retailer Search
    retailer_results = []
    threads << Thread.new do
      retailer_results = find_retailer_urls(gtin, market)
    end

@@ -129,110 +133,128 @@ class MasterDataHunter
      found: true,
      gtin: gtin,
      status: (web_data[:text].length > 100 ? "Found (Verified)" : "Registry Only"),
      market: market,
      image_url: display_image, 
      issuing_country: origin_country,
      **ai_result,
      defined_sources: confirmed_sources.uniq { |s| s[:url] }
    }
  end

  private

  def host_from_url(url)
    URI.parse(url).host.sub(/^www\./, '') rescue "Link"
  end

  # --- SEARCH METHODS ---
  
  def infer_name_from_ean(gtin, market)
    return nil if SERPAPI_KEY.nil?
    gl = (market == "UK" ? "gb" : market.downcase)
    begin
      # Quick check to see if Google knows the title
      res = GoogleSearch.new(q: "#{gtin}", gl: gl, num: 2, api_key: SERPAPI_KEY).get_hash
      first_result = (res[:organic_results] || []).first
      return first_result[:title].split(/ [|-] /).first.strip if first_result
      first_result = array_from_result(res, :organic_results).first
      title = value_from_result(first_result, :title)
      return title.split(/ [|-] /).first.strip if title
    rescue; end
    nil
  end

  def find_retailer_urls(gtin, market)
    return [] if SERPAPI_KEY.nil?
    gl = (market == "UK" ? "gb" : market.downcase)
    goldmine = @goldmine_sites[market]
    bans = "-site:pinterest.* -site:tiktok.com -site:facebook.com -site:youtube.com"
    return [] unless goldmine
    
    urls = []
    begin
      res = GoogleSearch.new(q: "#{goldmine} #{gtin} #{bans}", gl: gl, num: 3, api_key: SERPAPI_KEY).get_hash
      (res[:organic_results] || []).each { |r| urls << r[:link] }
      array_from_result(res, :organic_results).each do |r|
        link = value_from_result(r, :link)
        urls << link if link
      end
    rescue; end
    urls
  end

  def find_deep_urls(name, market)
    return [] if name.nil? || name.length < 3
    gl = (market == "UK" ? "gb" : market.downcase)
    bans = "-site:pinterest.* -site:tiktok.com -site:facebook.com -site:instagram.com"
    clean_name = name.gsub(/[^a-zA-Z0-9\s]/, '')
    
    urls = []
    begin
      # Explicitly asking for ingredients
      res = GoogleSearch.new(q: "#{clean_name} ingredients nutrition #{bans}", gl: gl, num: 3, api_key: SERPAPI_KEY).get_hash
      (res[:organic_results] || []).each { |r| urls << r[:link] }
      array_from_result(res, :organic_results).each do |r|
        link = value_from_result(r, :link)
        urls << link if link
      end
    rescue; end
    urls
  end

  # --- IMAGE DOWNLOADER ---
  def find_best_image(gtin, market)
    return nil if SERPAPI_KEY.nil?
    gl = (market == "UK" ? "gb" : market.downcase)
    bans = "-site:openfoodfacts.org"

    begin
      res = GoogleSearch.new(q: "#{gtin} product #{bans}", tbm: "isch", gl: gl, num: 3, api_key: SERPAPI_KEY).get_hash
      images = (res[:images_results] || []).first(2) 
      images = array_from_result(res, :images_results).first(2)
      
      images.each do |img|
        url = img[:original]
        url = value_from_result(img, :original)
        next if url.nil? || url.include?("placeholder")
        begin
          # Strict 4s timeout
          tempfile = Down.download(url, max_size: 1 * 1024 * 1024, timeout_open: 4, timeout_read: 4, headers: { "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" })
          base64 = Base64.strict_encode64(File.read(tempfile.path))
          return { url: url, source: img[:link], base64: base64 }
          return { url: url, source: value_from_result(img, :link), base64: base64 }
        rescue; next; end
      end
    rescue; end
    nil
  end

  def value_from_result(hash, key)
    return nil unless hash.is_a?(Hash)

    hash[key] || hash[key.to_s]
  end

  def array_from_result(hash, key)
    value = value_from_result(hash, key)
    value.is_a?(Array) ? value : []
  end

  # --- PARALLEL SCRAPER (The Stability Core) ---
  def fetch_parallel_page_data(urls)
    return { text: "", valid_urls: [] } if urls.empty?

    threads = []
    results_text = []
    valid_urls = []
    
    urls.each do |url|
      threads << Thread.new do
        # WRAPPER: Each scraper gets its own safe environment
        begin
          Timeout.timeout(6) do # 6s per site. If site is slower, we skip it.
            agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            response = HTTParty.get(url, headers: { "User-Agent" => agent }, timeout: 5)
            
            if response.code == 200
              doc = Nokogiri::HTML(response.body)
              doc.css('script, style, nav, footer, iframe, header, .cookie').remove
              txt = doc.text.gsub(/\s+/, " ").strip[0..8000]
              
              json_ld = ""
              doc.css('script[type="application/ld+json"]').each { |s| json_ld += s.content.to_s.gsub(/\s+/, " ").strip[0..3000] + " " }
              
              # Ignore PicClick/low-quality automated pages
@@ -550,26 +572,26 @@ __END__
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
</html>
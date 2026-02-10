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

  def initialize
    @headers = { 'Content-Type' => 'application/json' }

    # 1. MARKET DEFINITIONS
    @country_langs = {
      "DE" => "German", "AT" => "German", "CH" => "German",
      "UK" => "English", "GB" => "English", "FR" => "French",
      "BE" => "French", "IT" => "Italian", "ES" => "Spanish",
      "NL" => "Dutch", "DK" => "Danish", "SE" => "Swedish",
      "NO" => "Norwegian", "PL" => "Polish", "PT" => "Portuguese"
    }

    # 2. THE GOLDMINE (Trusted Retailers)
    @goldmine_sites = {
      "FR" => "site:carrefour.fr OR site:auchan.fr OR site:coursesu.com OR site:intermarche.com OR site:monoprix.fr OR site:franprix.fr",
      "UK" => "site:tesco.com OR site:sainsburys.co.uk OR site:asda.com OR site:morrisons.com OR site:iceland.co.uk OR site:waitrose.com",
      "NL" => "site:ah.nl OR site:jumbo.com OR site:plus.nl OR site:dirk.nl OR site:vomar.nl",
      "BE" => "site:delhaize.be OR site:colruyt.be OR site:carrefour.be OR site:ah.be",
      "DE" => "site:rewe.de OR site:edeka.de OR site:kaufland.de OR site:dm.de OR site:rossmann.de",
      "DK" => "site:nemlig.com OR site:bilkatogo.dk OR site:rema1000.dk OR site:netto.dk",
      "IT" => "site:carrefour.it OR site:conad.it OR site:esselunga.it OR site:coop.it",
      "ES" => "site:carrefour.es OR site:mercadona.es OR site:dia.es OR site:alcampo.es",
      "SE" => "site:ica.se OR site:coop.se OR site:willys.se OR site:hemkop.se",
      "NO" => "site:oda.com OR site:meny.no OR site:spar.no",
      "PL" => "site:carrefour.pl OR site:auchan.pl OR site:biedronka.pl",
      "PT" => "site:continente.pt OR site:auchan.pt OR site:pingo-doce.pt"
    }
  end

  def process_product(gtin, market)
    if GEMINI_API_KEY.nil? || GEMINI_API_KEY.strip.empty?
      return { found: false, status: "Missing GEMINI_API_KEY" }
    end

    # STEP A: OFFICIAL REGISTRY CHECK (The Anchor)
    official_data = fetch_official_ean_data(gtin)
    
    # STEP B: IMAGE HUNT
    image_data = find_best_image(gtin, market)

    # STEP C: EAN-BASED WEB HUNT
    candidate_urls = find_candidate_sources(gtin, market, :ean)
    combined_content = fetch_multi_page_data(candidate_urls)

    # STEP D: FIRST ANALYSIS
    ai_result = analyze_with_gemini(image_data ? image_data[:base64] : nil, combined_content, official_data, gtin, market)

    # --- NEW: STEP E: INTELLIGENT FALLBACK (Name-Based Search) ---
    # If ingredients are missing/short, AND we have a valid name, TRY AGAIN.
    if needs_fallback?(ai_result)
      
      # Determine best name to search: Official > AI Result > Generic
      search_name = official_data ? official_data['name'] : ai_result["product_name"]
      
      if search_name && search_name.length > 3 && !search_name.include?("Webdaten")
        puts "🔄 Fallback triggered: Searching for '#{search_name}'..."
        
        # 1. Search by Name
        name_urls = find_candidate_sources(search_name, market, :name)
        
        # 2. Fetch New Content
        fallback_content = fetch_multi_page_data(name_urls)
        
        # 3. Re-Analyze with BOTH old EAN content and new Name content
        # We append the new content to the old to give AI maximum context
        full_context = combined_content + "\n\n=== FALLBACK NAME SEARCH DATA ===\n" + fallback_content
        
        # 4. Run AI Again
        ai_result = analyze_with_gemini(image_data ? image_data[:base64] : nil, full_context, official_data, gtin, market)
        ai_result["status"] = "Deep Search (Found)" # Update status so user knows we worked hard
      end
    end

    # Handle Errors
    if ai_result.is_a?(Hash) && ai_result[:error]
      return empty_result(gtin, market, ai_result[:error], image_data ? image_data[:url] : nil)
    end

    {
      found: true,
      gtin: gtin,
      status: ai_result["status"] || "Found",
      market: market,
      image_url: image_data ? image_data[:url] : nil,
      **ai_result
    }
  end

  private

  # Check if the result is "bad" enough to warrant a second search
  def needs_fallback?(result)
    return true if result[:error] # If it failed, retry
    
    ing = result["ingredients"].to_s.downcase
    nut = result["energy"].to_s.downcase
    
    # Retry if ingredients are missing, "unknown", or "no data"
    missing_ingredients = ing.length < 10 || ing.include?("keine") || ing.include?("not found") || ing.include?("unavailable")
    missing_nutrition = nut.include?("undefined") || nut.include?("keine") || nut.length < 2

    missing_ingredients || missing_nutrition
  end

  def fetch_official_ean_data(gtin)
    return nil if EAN_SEARCH_TOKEN.nil? || EAN_SEARCH_TOKEN.empty?
    begin
      url = "https://api.ean-search.org/api?token=#{EAN_SEARCH_TOKEN}&op=barcode-lookup&format=json&ean=#{gtin}"
      response = HTTParty.get(url, timeout: 5)
      if response.code == 200
        json = JSON.parse(response.body)
        return json.first if json.is_a?(Array) && !json.empty?
      end
    rescue => e
      puts "⚠️ EAN-Search API failed: #{e.message}"
    end
    nil
  end

  def serp_gl_for_market(market)
    return "gb" if market == "UK"
    market.to_s.downcase
  end

  def find_best_image(gtin, market)
    return nil if SERPAPI_KEY.nil? || SERPAPI_KEY.strip.empty?
    gl = serp_gl_for_market(market)
    
    query = "site:barcodelookup.com OR site:go-upc.com OR site:amazon.* \"#{gtin}\""
    res = GoogleSearch.new(q: query, tbm: "isch", gl: gl, api_key: SERPAPI_KEY).get_hash

    if (res[:images_results] || []).empty?
      bans = "-site:openfoodfacts.org -site:world.openfoodfacts.org"
      res = GoogleSearch.new(q: "#{gtin} #{bans}", tbm: "isch", gl: gl, api_key: SERPAPI_KEY).get_hash
    end

    (res[:images_results] || []).first(5).each do |img|
      url = img[:original]
      next if url.nil? || url.include?("placeholder")
      begin
        tempfile = Down.download(url, max_size: 5 * 1024 * 1024)
        base64 = Base64.strict_encode64(File.read(tempfile.path))
        return { url: url, source: img[:link], base64: base64 }
      rescue
        next
      end
    end
    nil
  end

  # UPDATED: Handles both EAN and NAME searches
  def find_candidate_sources(query_term, market, type = :ean)
    return [] if SERPAPI_KEY.nil? || SERPAPI_KEY.strip.empty?

    candidates = []
    gl = serp_gl_for_market(market)
    goldmine = @goldmine_sites[market]
    bans = "-site:openfoodfacts.org -site:wikipedia.org -site:amazon.* -site:ebay.* -site:pinterest.*"

    # Construct Query based on Type
    if type == :ean
      # Strategy A: Retailer EAN Search
      if goldmine
        res = GoogleSearch.new(q: "#{goldmine} #{query_term} #{bans}", gl: gl, num: 5, api_key: SERPAPI_KEY).get_hash
        (res[:organic_results] || []).each { |r| candidates << r[:link] }
      end
      
      # Strategy B: General EAN Search (if retailers fail)
      if candidates.length < 2
        res = GoogleSearch.new(q: "#{query_term} ingredients nutrition #{bans}", gl: gl, num: 5, api_key: SERPAPI_KEY).get_hash
        (res[:organic_results] || []).each { |r| candidates << r[:link] }
      end

    elsif type == :name
      # Strategy C: Name Search (The Hail Mary)
      # We append "ingredients" in the local language would be better, but English works often
      q_string = "#{query_term} ingredients nutrition #{bans}"
      puts "🔎 FALLBACK SEARCH: #{q_string}"
      res = GoogleSearch.new(q: q_string, gl: gl, num: 5, api_key: SERPAPI_KEY).get_hash
      (res[:organic_results] || []).each { |r| candidates << r[:link] }
    end

    candidates.uniq.first(4)
  end

  def fetch_multi_page_data(urls)
    return "" if urls.empty?

    threads = []
    results = []
    
    urls.each_with_index do |url, index|
      threads << Thread.new do
        begin
          Timeout.timeout(6) do
            user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            response = HTTParty.get(url, headers: { "User-Agent" => user_agent }, timeout: 5)
            
            if response.code == 200
              html = response.body.to_s
              doc = Nokogiri::HTML(html)
              doc.css('script, style, nav, footer, iframe, header, ad, .cookie-banner').remove
              
              # Capture visual text
              text_content = doc.text.gsub(/\s+/, " ").strip[0..3000]
              
              # Capture JSON-LD (Critical for nutrition)
              json_ld = ""
              doc.css('script[type="application/ld+json"]').each do |s|
                 json_ld += s.content.to_s.gsub(/\s+/, " ").strip[0..2000] + " "
              end

              results << "=== SOURCE: #{url} ===\nCONTENT: #{text_content}\nJSON-LD: #{json_ld}\n\n"
            end
          end
        rescue; end
      end
    end

    threads.each(&:join)
    results.join("\n")
  end

  def analyze_with_gemini(base64_image, multi_source_text, official_data, gtin, market)
    target_lang = @country_langs[market] || "English"
    
    official_info_text = "OFFICIAL REGISTRY DATA: None"
    if official_data
      official_info_text = <<~TXT
        OFFICIAL REGISTRY DATA (High Trust for Name):
        - Name: #{official_data['name']}
        - Category: #{official_data['categoryName']}
      TXT
    end

    # UPDATED PROMPT: STRICT TRANSLATION
    prompt_text = <<~TEXT
      You are the Lead Food Product Researcher.
      
      #{official_info_text}

      INPUT DATA (Web Scrapes + JSON-LD):
      #{multi_source_text}

      #{base64_image ? "IMAGE ATTACHED: Yes" : "IMAGE ATTACHED: No"}

      TASK: 
      1. Synthesis: Combine Official Data (trust for Name) + Web Data (trust for Ingredients/Nutri) + Image.
      2. LANGUAGE STRICTNESS: 
         - The Target Language is: #{target_lang.upcase}.
         - You MUST translate ALL Output (Ingredients, Name, Allergens) into #{target_lang}.
         - Do NOT output Hungarian, Polish, or English if the target is German. TRANSLATE IT.
      3. Logic:
         - If Official Name is generic, prefer a detailed retailer name.
         - If Web Data is empty, look at the Image.

      OUTPUT JSON FORMAT:
      {
        "product_name": "Brand + Name (Translated)",
        "ingredients": "Full List (Translated)",
        "allergens": "List (Translated)",
        "nutri_scope": "Per 100g or Per Serving",
        "energy": "kJ / kcal",
        "fat": "Value",
        "saturates": "Value",
        "carbs": "Value",
        "sugars": "Value",
        "protein": "Value",
        "fiber": "Value",
        "salt": "Value",
        "organic_id": "Code",
        "sources_summary": "Short text (e.g. 'Registry + Tesco')",
        "source_links": ["Full URL 1", "Full URL 2"] 
      }
    TEXT

    models_to_try = ["models/gemini-2.0-flash", "models/gemini-2.0-flash-lite", "models/gemini-1.5-flash"]
    parts = [{ text: prompt_text }]
    parts << { inline_data: { mime_type: "image/jpeg", data: base64_image } } if base64_image

    models_to_try.each do |model_id|
      url = "https://generativelanguage.googleapis.com/v1beta/#{model_id}:generateContent?key=#{GEMINI_API_KEY}"
      begin
        response = HTTParty.post(url, body: { contents: [{ parts: parts }] }.to_json, headers: @headers, timeout: 40)
        if response.code == 200
          raw_text = response.dig("candidates", 0, "content", "parts", 0, "text")
          next if raw_text.nil?
          clean_json = raw_text.gsub(/```json/i, "").gsub(/```/, "").strip
          return JSON.parse(clean_json)
        end
      rescue; next; end
    end

    { error: "AI Processing Failed" }
  end

  def empty_result(gtin, market, status_msg, img_url = nil)
    {
      found: false, status: status_msg, gtin: gtin, market: market, image_url: img_url,
      product_name: "-", ingredients: "-", allergens: "-", organic_id: "-",
      sources_summary: "No data found", source_links: []
    }
  end
end

# --- ROUTES ---

get '/' do
  erb :index
end

get '/api/search' do
  content_type :json
  hunter = MasterDataHunter.new
  result = hunter.process_product(params[:gtin], params[:market])
  result.to_json
end

__END__

@@ index
<!DOCTYPE html>
<html>
<head>
  <title>TGTG AI Data Hunter v2.2 (Deep Search)</title>
  <style>
    body { font-family: -apple-system, system-ui, sans-serif; background: #f4f6f8; padding: 20px; color: #333; }
    .container { max-width: 98%; margin: 0 auto; background: white; padding: 25px; border-radius: 12px; box-shadow: 0 2px 10px rgba(0,0,0,0.05); }
    h1 { color: #00816A; }
    .controls { display: flex; gap: 15px; margin-bottom: 20px; background: #eefcf9; padding: 15px; border-radius: 8px; }
    textarea { width: 100%; height: 100px; padding: 12px; border: 1px solid #ddd; border-radius: 8px; font-family: monospace; }
    button { background: #00816A; color: white; border: none; padding: 12px 24px; border-radius: 6px; font-weight: 600; cursor: pointer; }
    button:disabled { background: #ccc; }
    
    .table-wrapper { overflow-x: auto; margin-top: 25px; border: 1px solid #eee; border-radius: 8px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; min-width: 2800px; }
    th { text-align: left; background: #00816A; color: white; padding: 12px; position: sticky; left: 0; z-index: 10; white-space: nowrap; }
    td { padding: 12px; border-bottom: 1px solid #eee; vertical-align: top; max-width: 300px; word-wrap: break-word; }
    tr:nth-child(even) { background: #f8f9fa; }

    .status-found { background: #d4edda; color: #155724; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
    .status-deep { background: #cce5ff; color: #004085; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
    .status-missing { background: #f8d7da; color: #721c24; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
    .img-preview { width: 60px; height: 60px; object-fit: contain; border: 1px solid #ddd; border-radius: 4px; background: white; }
    
    .source-pill { 
      display: inline-block; background: #e9ecef; color: #333; 
      padding: 2px 6px; border-radius: 4px; font-size: 10px; margin: 2px; text-decoration: none; border: 1px solid #ccc;
    }
    .source-pill:hover { background: #00816A; color: white; border-color: #00816A; }
    .source-summary { font-size: 11px; font-style: italic; color: #555; display: block; margin-bottom: 4px; }
  </style>
</head>
<body>

<div class="container">
  <h1>✨ TGTG AI Data Hunter <span style="font-size:0.6em; opacity:0.6">v2.2 (Deep Search)</span></h1>
  <div class="controls">
    <select id="marketSelect" style="padding: 8px; border-radius: 4px;">
      <option value="DE">Germany (DE)</option>
      <option value="UK">United Kingdom (UK)</option>
      <option value="FR">France (FR)</option>
      <option value="NL">Netherlands (NL)</option>
      <option value="BE">Belgium (BE)</option>
      <option value="IT">Italy (IT)</option>
      <option value="ES">Spain (ES)</option>
      <option value="DK">Denmark (DK)</option>
    </select>
  </div>

  <textarea id="inputList" placeholder="Paste EANs here..."></textarea>
  <br><br>
  <button id="startBtn" onclick="startBatch()">🚀 Start Deep Analysis</button>
  <button id="downloadBtn" onclick="downloadCSV()" style="background: #333; display: none;">⬇️ Download CSV</button>
  <p id="statusText" style="color: #666; margin-top: 10px;">Ready.</p>

  <div class="table-wrapper">
    <table id="resultsTable">
      <thead>
        <tr>
          <th>Status</th>
          <th>Img</th>
          <th>EAN</th>
          <th>Product Name</th>
          <th>Ingredients</th>
          <th>Allergens</th>
          <th>Nutri Scope</th>
          <th>Energy</th>
          <th>Fat</th>
          <th>Saturates</th>
          <th>Carbs</th>
          <th>Sugars</th>
          <th>Protein</th>
          <th>Fiber</th>
          <th>Salt</th>
          <th>Organic ID</th>
          <th>Sources & Links</th>
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

    if (lines.length === 0) { alert("Paste EANs first!"); return; }

    document.getElementById('startBtn').disabled = true;
    const tbody = document.querySelector('#resultsTable tbody');
    tbody.innerHTML = "";
    resultsData = [];

    let processed = 0;

    for (const gtin of lines) {
      document.getElementById('statusText').innerText = `Analyzing ${gtin} (${processed + 1}/${lines.length})...`;
      const tr = document.createElement('tr');
      let emptyCells = ""; for(let i=0; i<15; i++) { emptyCells += "<td></td>"; }
      tr.innerHTML = `<td style="color:#00816A; font-weight:bold;">Hunting...</td>` + emptyCells;
      tbody.appendChild(tr);

      try {
        const response = await fetch(`/api/search?gtin=${gtin}&market=${market}`);
        const data = await response.json();

        let displayStatus = data.status;
        let statusClass = 'status-found';
        if (displayStatus.includes("Deep")) statusClass = 'status-deep';
        if (displayStatus.includes("Error") || displayStatus.includes("Missing")) statusClass = 'status-missing';
        
        const imgHTML = data.image_url ? `<a href="${data.image_url}" target="_blank"><img src="${data.image_url}" class="img-preview"></a>` : '-';
        
        // Build Sources HTML
        let sourcesHTML = `<span class="source-summary">${data.sources_summary || '-'}</span><br>`;
        if(data.source_links && Array.isArray(data.source_links)) {
           data.source_links.forEach((link, idx) => {
              let domain = link;
              try { domain = new URL(link).hostname.replace('www.',''); } catch(e){}
              sourcesHTML += `<a href="${link}" target="_blank" class="source-pill">🔗 ${domain}</a>`;
           });
        }

        tr.innerHTML = `
          <td><span class="${statusClass}">${displayStatus}</span></td>
          <td>${imgHTML}</td>
          <td>${gtin}</td>
          <td>${data.product_name}</td>
          <td>${data.ingredients}</td>
          <td>${data.allergens}</td>
          <td>${data.nutri_scope}</td>
          <td>${data.energy}</td>
          <td>${data.fat}</td>
          <td>${data.saturates}</td>
          <td>${data.carbs}</td>
          <td>${data.sugars}</td>
          <td>${data.protein}</td>
          <td>${data.fiber}</td>
          <td>${data.salt}</td>
          <td>${data.organic_id}</td>
          <td>${sourcesHTML}</td>
        `;
        resultsData.push(data);
      } catch (e) {
        tr.innerHTML = `<td style="color:red">Error</td>` + emptyCells;
      }
      processed++;
    }
    document.getElementById('startBtn').disabled = false;
    document.getElementById('downloadBtn').style.display = "inline-block";
    document.getElementById('statusText').innerText = "Batch Complete!";
  }

  function downloadCSV() {
    let csv = "EAN,ProductName,Status,Ingredients,Allergens,OrganicID,SourcesUsed,SourceLinks\n";
    resultsData.forEach(row => {
      const clean = (txt) => (txt || "-").toString().replace(/,/g, " ").replace(/\n/g, " ").trim();
      const links = (row.source_links || []).join(" | ");
      csv += `${row.gtin},${clean(row.product_name)},${row.status},` +
             `${clean(row.ingredients)},${clean(row.allergens)},${clean(row.organic_id)},` +
             `${clean(row.sources_summary)},${links}\n`;
    });
    const link = document.createElement("a");
    link.href = "data:text/csv;charset=utf-8," + encodeURI(csv);
    link.download = "tgtg_ai_results_v2.csv";
    link.click();
  }
</script>

</body>
</html>
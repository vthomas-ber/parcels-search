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

    # Task B: Deep Search (Only if we have a name, or can infer one)
    deep_results = []
    threads << Thread.new do
      # If registry name is missing, we try to guess it from a quick Google query first
      search_name = registry_name || infer_name_from_ean(gtin, market)
      deep_results = find_deep_urls(search_name, market) if search_name
    end

    # Task C: Image Search
    image_data = nil
    threads << Thread.new do
      image_data = find_best_image(gtin, market)
    end

    # Wait for all searches to finish (Max 5 seconds wait)
    threads.each { |t| t.join(5) }

    # Combine URLs (Retailer First, then Deep)
    all_urls = (retailer_results + deep_results).uniq.first(5) # Cap at 5 total URLs to scrape

    # --- STEP 3: PARALLEL SCRAPING ---
    # Now we scrape the 5 URLs found, all at once.
    web_data = fetch_parallel_page_data(all_urls)
    web_data[:valid_urls].each { |u| confirmed_sources << { type: "web", title: host_from_url(u), url: u } }
    
    if image_data
      confirmed_sources << { type: "image", title: "Source Image", url: image_data[:url] }
    end

    # --- STEP 4: AI ANALYSIS ---
    # Fail fast only if truly blind
    if (image_data.nil? || image_data[:base64].nil?) && web_data[:text].strip.empty?
      return empty_result(gtin, market, "No Data Found (Blind)", nil)
    end

    final_name_context = official_data ? official_data : { 'name' => registry_name }

    ai_result = analyze_with_gemini(
      image_data ? image_data[:base64] : nil, 
      web_data[:text], 
      final_name_context, 
      gtin, 
      market
    )

    if ai_result[:error]
      return empty_result(gtin, market, ai_result[:error], image_data ? image_data[:url] : nil)
    end

    origin_country = official_data ? official_data['issuingCountry'] : nil
    display_image = image_data && image_data[:base64] ? "data:image/jpeg;base64,#{image_data[:base64]}" : (image_data ? image_data[:url] : nil)

    {
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
      
      images.each do |img|
        url = img[:original]
        next if url.nil? || url.include?("placeholder")
        begin
          # Strict 4s timeout
          tempfile = Down.download(url, max_size: 5 * 1024 * 1024, timeout_open: 4, timeout_read: 4, headers: { "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" })
          base64 = Base64.strict_encode64(File.read(tempfile.path))
          return { url: url, source: img[:link], base64: base64 }
        rescue; next; end
      end
    rescue; end
    nil
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
              if txt.length > 200
                Thread.current[:valid] = url
                Thread.current[:text] = "=== SOURCE: #{url} ===\nCONTENT: #{txt}\nJSON-LD: #{json_ld}\n\n"
              end
            end
          end
        rescue; end # Fail silently for this URL, let others finish
      end
    end

    threads.each do |t| 
      t.join
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
      resp = HTTParty.get(url, timeout: 3)
      return JSON.parse(resp.body).first if resp.code == 200 rescue nil
    rescue; nil; end
  end

  def analyze_with_gemini(base64_image, text_data, official, gtin, market)
    target_lang = @country_langs[market] || "English"
    name_info = official ? official['name'] : (official.is_a?(Hash) ? official['name'] : "Unknown")
    official_txt = "PRODUCT IDENTITY: #{name_info}"

    prompt = <<~TEXT
      You are a Food Data Expert.
      #{official_txt}
      
      INPUT DATA:
      #{text_data}
      #{base64_image ? "IMAGE: Provided" : "IMAGE: Not Available"}

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
    parts << { inline_data: { mime_type: "image/jpeg", data: base64_image } } if base64_image

    models.each do |m|
      url = "https://generativelanguage.googleapis.com/v1beta/#{m}:generateContent?key=#{GEMINI_API_KEY}"
      begin
        resp = HTTParty.post(url, body: { contents: [{ parts: parts }] }.to_json, headers: @headers, timeout: 35)
        if resp.code == 200
          raw = resp.dig("candidates", 0, "content", "parts", 0, "text")
          next unless raw
          return JSON.parse(raw.gsub(/```json|```/, "").strip)
        end
      rescue; next; end
    end
    { error: "AI Failed to Analyze" }
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
    { found: false, status: "Server Error: #{e.message}", gtin: params[:gtin] }.to_json
  end
end

__END__

@@ index
<!DOCTYPE html>
<html>
<head>
  <title>TGTG AI Hunter v3.6 (Parallel)</title>
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
    <h1>✨ TGTG AI Hunter <span style="font-size:0.5em; color:#666; font-weight:normal;">v3.6 (Parallel)</span></h1>
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
        if (data.status.includes("Error") || data.status.includes("Missing") || data.status.includes("Server")) sClass = 'st-miss';

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
        
        const fmt = (text) => (text || "-").replace(/\n/g, "<br>");

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
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
    
    # 3. Market Language Logic (Special Handling for BE)
    @country_langs = {
      "DE" => "German", 
      "AT" => "German", 
      "CH" => "German",
      "UK" => "English", 
      "GB" => "English", 
      "FR" => "French",
      "IT" => "Italian", 
      "ES" => "Spanish",
      "NL" => "Dutch", 
      "DK" => "Danish", 
      "SE" => "Swedish",
      "NO" => "Norwegian", 
      "PL" => "Polish", 
      "PT" => "Portuguese",
      "BE" => "German, French, AND Dutch (Must provide all 3)"
    }

    # 2. THE GOLDMINE (Trusted Retailers)
    @goldmine_sites = {
      "FR" => "site:carrefour.fr OR site:auchan.fr OR site:coursesu.com OR site:intermarche.com OR site:monoprix.fr",
      "UK" => "site:tesco.com OR site:sainsburys.co.uk OR site:asda.com OR site:morrisons.com OR site:waitrose.com",
      "NL" => "site:ah.nl OR site:jumbo.com OR site:plus.nl OR site:dirk.nl",
      "BE" => "site:delhaize.be OR site:colruyt.be OR site:carrefour.be OR site:ah.be",
      "DE" => "site:rewe.de OR site:edeka.de OR site:kaufland.de OR site:dm.de OR site:rossmann.de",
      "AT" => "site:billa.at OR site:spar.at OR site:hofer.at OR site:unimarkt.at OR site:gurkerl.at",
      "DK" => "site:nemlig.com OR site:bilkatogo.dk OR site:rema1000.dk OR site:netto.dk",
      "IT" => "site:carrefour.it OR site:conad.it OR site:esselunga.it OR site:coop.it",
      "ES" => "site:carrefour.es OR site:mercadona.es OR site:dia.es OR site:alcampo.es",
      "SE" => "site:ica.se OR site:coop.se OR site:willys.se OR site:hemkop.se",
      "NO" => "site:oda.com OR site:meny.no OR site:spar.no",
      "PL" => "site:carrefour.pl OR site:auchan.pl OR site:biedronka.pl OR site:kaufland.pl",
      "PT" => "site:continente.pt OR site:auchan.pt OR site:pingo-doce.pt"
    }
  end

  def process_product(gtin, market)
    return { found: false, status: "Missing GEMINI_API_KEY" } if GEMINI_API_KEY.nil? || GEMINI_API_KEY.empty?

    confirmed_sources = []

    # 1. OFFICIAL REGISTRY
    official_data = fetch_official_ean_data(gtin)
    if official_data
      confirmed_sources << { type: "registry", title: "Official Registry", url: "https://www.ean-search.org/?q=#{gtin}" }
    end

    # 2. IMAGE HUNT
    image_data = find_best_image(gtin, market)
    if image_data
      confirmed_sources << { type: "image", title: "Source Image", url: image_data[:url] }
    end

    # 3. WEB HUNT (Standard)
    candidate_urls = find_candidate_sources(gtin, market, :ean)
    web_data = fetch_multi_page_data(candidate_urls)
    web_data[:valid_urls].each { |u| confirmed_sources << { type: "web", title: host_from_url(u), url: u } }

    # 4. FIRST ANALYSIS
    ai_result = analyze_with_gemini(image_data ? image_data[:base64] : nil, web_data[:text], official_data, gtin, market)

    # 5. DEEP SEARCH FALLBACK (Name-Based)
    if needs_fallback?(ai_result)
      search_name = official_data ? official_data['name'] : ai_result["product_name"]
      
      # Clean name for search
      if search_name && search_name.length > 3 && !search_name.include?("Webdaten")
        puts "🔄 Deep Search for: #{search_name}"
        name_urls = find_candidate_sources(search_name, market, :name)
        fallback_data = fetch_multi_page_data(name_urls)
        
        fallback_data[:valid_urls].each { |u| confirmed_sources << { type: "web", title: host_from_url(u), url: u } }

        full_context = web_data[:text] + "\n\n=== FALLBACK NAME SEARCH ===\n" + fallback_data[:text]
        ai_result = analyze_with_gemini(image_data ? image_data[:base64] : nil, full_context, official_data, gtin, market)
        ai_result["status"] = "Deep Search (Found)"
      end
    end

    if ai_result[:error]
      return empty_result(gtin, market, ai_result[:error], image_data ? image_data[:url] : nil)
    end

    # Extract country from official data if available
    origin_country = official_data ? official_data['issuingCountry'] : nil

    {
      found: true,
      gtin: gtin,
      status: ai_result["status"] || "Found",
      market: market,
      image_url: image_data ? image_data[:url] : nil,
      issuing_country: origin_country,
      **ai_result,
      defined_sources: confirmed_sources
    }
  end

  private

  def host_from_url(url)
    URI.parse(url).host.sub(/^www\./, '') rescue url
  end

  def needs_fallback?(result)
    return true if result[:error]
    ing = result["ingredients"].to_s.downcase
    
    # Retry if ingredients are missing or strictly English "not found"
    missing_ing = ing.length < 10 || ing.include?("keine") || ing.include?("not found")
    missing_ing
  end

  def fetch_official_ean_data(gtin)
    return nil if EAN_SEARCH_TOKEN.nil? || EAN_SEARCH_TOKEN.empty?
    begin
      url = "https://api.ean-search.org/api?token=#{EAN_SEARCH_TOKEN}&op=barcode-lookup&format=json&ean=#{gtin}"
      resp = HTTParty.get(url, timeout: 5)
      return JSON.parse(resp.body).first if resp.code == 200 rescue nil
    rescue; nil; end
  end

  def find_best_image(gtin, market)
    return nil if SERPAPI_KEY.nil? || SERPAPI_KEY.empty?
    gl = (market == "UK" ? "gb" : market.downcase)
    
    res = GoogleSearch.new(q: "site:barcodelookup.com OR site:go-upc.com \"#{gtin}\"", tbm: "isch", gl: gl, api_key: SERPAPI_KEY).get_hash
    if (res[:images_results] || []).empty?
      res = GoogleSearch.new(q: "#{gtin} -site:openfoodfacts.org", tbm: "isch", gl: gl, api_key: SERPAPI_KEY).get_hash
    end

    (res[:images_results] || []).first(5).each do |img|
      url = img[:original]
      next if url.nil? || url.include?("placeholder")
      begin
        tempfile = Down.download(url, max_size: 5 * 1024 * 1024)
        base64 = Base64.strict_encode64(File.read(tempfile.path))
        return { url: url, source: img[:link], base64: base64 }
      rescue; next; end
    end
    nil
  end

  def find_candidate_sources(query, market, type)
    return [] if SERPAPI_KEY.nil? || SERPAPI_KEY.empty?
    gl = (market == "UK" ? "gb" : market.downcase)
    goldmine = @goldmine_sites[market]
    
    # --- CHANGE 1: UNBAN AMAZON, BAN TIKTOK ---
    bans = "-site:openfoodfacts.org -site:wikipedia.org -site:pinterest.* -site:tiktok.com -site:facebook.com -site:instagram.com"
    candidates = []

    if type == :ean && goldmine
      res = GoogleSearch.new(q: "#{goldmine} #{query} #{bans}", gl: gl, num: 5, api_key: SERPAPI_KEY).get_hash
      (res[:organic_results] || []).each { |r| candidates << r[:link] }
    end

    if candidates.empty? || type == :name
      q_str = "#{query} ingredients nutrition #{bans}"
      res = GoogleSearch.new(q: q_str, gl: gl, num: 5, api_key: SERPAPI_KEY).get_hash
      (res[:organic_results] || []).each { |r| candidates << r[:link] }
    end

    candidates.uniq.first(4)
  end

  def fetch_multi_page_data(urls)
    return { text: "", valid_urls: [] } if urls.empty?

    threads = []
    results_text = []
    valid_urls = []
    
    urls.each_with_index do |url, index|
      threads << Thread.new do
        begin
          Timeout.timeout(7) do
            agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            response = HTTParty.get(url, headers: { "User-Agent" => agent }, timeout: 6)
            
            if response.code == 200
              valid_urls << url
              doc = Nokogiri::HTML(response.body)
              doc.css('script, style, nav, footer, iframe, header, .cookie').remove
              
              txt = doc.text.gsub(/\s+/, " ").strip[0..12000]
              
              json = ""
              doc.css('script[type="application/ld+json"]').each { |s| json += s.content.to_s.gsub(/\s+/, " ").strip[0..4000] + " " }
              
              results_text << "=== SOURCE: #{url} ===\nCONTENT: #{txt}\nJSON-LD: #{json}\n\n"
            end
          end
        rescue; end
      end
    end
    threads.each(&:join)
    { text: results_text.join("\n"), valid_urls: valid_urls }
  end

  def analyze_with_gemini(base64_image, text_data, official, gtin, market)
    target_lang = @country_langs[market] || "English"
    
    official_txt = official ? "OFFICIAL REGISTRY IDENTITY: #{official['name']}" : "OFFICIAL REGISTRY: None"

    # --- CHANGE 2: PROMPT TWEAK FOR GARBAGE AVOIDANCE ---
    prompt = <<~TEXT
      You are a Food Data Expert.
      #{official_txt}
      
      INPUT DATA:
      #{text_data}
      #{base64_image ? "IMAGE: Yes" : "IMAGE: No"}

      MARKET REQUIREMENTS:
      - Target Market: #{market}
      - Target Languages: #{target_lang}
      
      TASK:
      1. Synthesize all data.
      2. **PRIORITY RULE:** If the Text Data contains social media noise, irrelevant comments, or "Login" prompts, IGNORE IT and rely on the Image or Official Registry.
      3. **PRODUCT NAME:** If an Official Registry name exists, use it as the base, BUT YOU MUST TRANSLATE IT to the primary language of the market (e.g., German for DE, French for BE).
      4. **BRAND:** Extract the Brand Name.
      5. **BELGIUM (BE) SPECIAL RULE:** If Market is 'BE', output Ingredients, Allergens, and 'May Contain' in THREE languages: German, French, and Dutch. Separate them clearly with line breaks.
      6. **NET WEIGHT:** Extract net weight (e.g. 200g, 500ml).
      7. **MAY CONTAIN:** Extract 'May contain' / traces info.

      OUTPUT JSON (Strictly this schema):
      {
        "brand": "Brand Name",
        "product_name": "Name (Translated)", 
        "net_weight": "Value",
        "ingredients": "List (Translated/Trilingual for BE)", 
        "allergens": "List (Translated/Trilingual for BE)",
        "may_contain": "List (Translated/Trilingual for BE)",
        "nutri_scope": "100g/ml", "energy": "kJ/kcal", "fat": "val", "saturates": "val",
        "carbs": "val", "sugars": "val", "protein": "val", "fiber": "val", "salt": "val",
        "organic_id": "Code", "sources_summary": "Short explanation"
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
    { error: "AI Failed" }
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
  hunter = MasterDataHunter.new
  result = hunter.process_product(params[:gtin], params[:market])
  result.to_json
end

__END__

@@ index
<!DOCTYPE html>
<html>
<head>
  <title>TGTG AI Hunter v2.7</title>
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
    .src-img { border-left: 3px solid #6f42c1; }
    .ai-note { font-size: 10px; color: #888; margin-bottom: 5px; font-style: italic; }
  </style>
</head>
<body>

<div class="container">
  <div style="display:flex; justify-content:space-between; align-items:center;">
    <h1>✨ TGTG AI Hunter <span style="font-size:0.5em; color:#666; font-weight:normal;">v2.7 (Amazon + Origin)</span></h1>
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
        if (data.status.includes("Deep")) sClass = 'st-deep';
        if (data.status.includes("Error") || data.status.includes("Missing")) sClass = 'st-miss';

        const imgHTML = data.image_url ? `<a href="${data.image_url}" target="_blank"><img src="${data.image_url}" class="img-thumb"></a>` : '-';

        let sourcesHTML = `<div class="source-list">`;
        if (data.sources_summary) sourcesHTML += `<span class="ai-note">${data.sources_summary}</span>`;
        if (data.defined_sources && data.defined_sources.length > 0) {
           data.defined_sources.forEach(src => {
              let icon = "🔗";
              let cssClass = "src-web";
              if(src.type === 'registry') { icon = "🏛️"; cssClass = "src-registry"; }
              if(src.type === 'image')    { icon = "📸"; cssClass = "src-img"; }
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
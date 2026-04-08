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

GEMINI_API_KEY   = ENV['GEMINI_API_KEY']
SERPAPI_KEY      = ENV['SERPAPI_KEY']
EAN_SEARCH_TOKEN = ENV['EAN_SEARCH_TOKEN']
ZENROWS_API_KEY  = ENV['ZENROWS_API_KEY']

BAD_URL_PATTERNS = %w[
  pinterest tiktok.com facebook.com instagram.com
  .xml .xml.gz .zip .gz sitemap
  scribd academia tamu.edu github trinket joybuy momogo
  onlinelibrary.wiley pubs.acs.org springer.com sciencedirect ncbi.nlm
  pubmed nature.com cell.com beslist ocen-piwo dunnesstoresgrocery
  unesdoc.unesco fitia.app
  world.openfoodfacts.org fr.openfoodfacts.org de.openfoodfacts.org
  nl.openfoodfacts.org es.openfoodfacts.org it.openfoodfacts.org
].freeze

ALLOWED_KEYS = %w[
  brand product_name item_description cn_code uom packaging fragile
  net_weight_g gross_weight_g organic dietary_info
  net_weight_display ingredients allergens may_contain
  nutri_scope energy_kj fat saturates carbs sugars protein fiber salt
  manufacturer_address place_of_origin organic_id
  pkg_length pkg_width pkg_height format occasion
  cat_l1 cat_l2 cat_l3 cat_l4 cat_l5 cat_l6
  sources_summary
].freeze

CATEGORY_TAXONOMY = [
  ["Drinks","Drinks","Hot Drinks","Tea","Tea Bags (Black)","Black"],
  ["Drinks","Drinks","Hot Drinks","Tea","Tea Bags (Green/ herbal/ Fruit)","Green"],
  ["Drinks","Drinks","Hot Drinks","Tea","Tea Bags (Green/ herbal/ Fruit)","Herbal"],
  ["Drinks","Drinks","Hot Drinks","Tea","Tea Bags (Green/ herbal/ Fruit)","Fruit"],
  ["Drinks","Drinks","Hot Drinks","Tea","Loose Leaf Tea","Black"],
  ["Drinks","Drinks","Hot Drinks","Tea","Loose Leaf Tea","Green"],
  ["Drinks","Drinks","Hot Drinks","Coffee","Coffee Pods","Standard"],
  ["Drinks","Drinks","Hot Drinks","Coffee","Coffee Pods","Flavoured"],
  ["Drinks","Drinks","Hot Drinks","Coffee","Instant Coffee","Standard"],
  ["Drinks","Drinks","Hot Drinks","Coffee","Instant Coffee","Flavoured"],
  ["Drinks","Drinks","Hot Drinks","Coffee","Ground Coffee Bags","Standard"],
  ["Drinks","Drinks","Hot Drinks","Coffee","Coffee Beans Bags","Standard"],
  ["Drinks","Drinks","Hot Drinks","Hot Chocolate/ Other","Chocolate Powder","Chocolate"],
  ["Drinks","Drinks","Hot Drinks","Hot Chocolate/ Other","Chocolate Powder","Flavoured Chocolate"],
  ["Drinks","Drinks","Hot Drinks","Hot Chocolate/ Other","Malted Drinks","Malted"],
  ["Drinks","Drinks","Soft Drinks","Carbonated","Cola","Standard"],
  ["Drinks","Drinks","Soft Drinks","Carbonated","Cola","Diet"],
  ["Drinks","Drinks","Soft Drinks","Carbonated","Cola","Zero"],
  ["Drinks","Drinks","Soft Drinks","Carbonated","Cola","Flavoured"],
  ["Drinks","Drinks","Soft Drinks","Carbonated","Fizzy","Lemon/ lime"],
  ["Drinks","Drinks","Soft Drinks","Carbonated","Fizzy","Orange"],
  ["Drinks","Drinks","Soft Drinks","Carbonated","Fizzy","Ginger Beer"],
  ["Drinks","Drinks","Soft Drinks","Carbonated","Fizzy","Other Flavoured"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Juice","Orange"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Juice","Apple"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Juice","Tropical"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Juice","Coconut"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Smoothies","Berry"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Smoothies","Tropical"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Smoothies","Other"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Squash/ Cordials","Orange"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Squash/ Cordials","Berries"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Squash/ Cordials","Tropical"],
  ["Drinks","Drinks","Soft Drinks","Juice/ Cordials","Squash/ Cordials","Other"],
  ["Drinks","Drinks","Soft Drinks","Iced","Iced Tea","Peach"],
  ["Drinks","Drinks","Soft Drinks","Iced","Iced Tea","Lemon"],
  ["Drinks","Drinks","Soft Drinks","Iced","Iced Tea","Other"],
  ["Drinks","Drinks","Soft Drinks","Iced","Iced Coffee","Standard"],
  ["Drinks","Drinks","Soft Drinks","Iced","Iced Coffee","Flavoured"],
  ["Drinks","Drinks","Soft Drinks","Adult","Mixers","Tonic"],
  ["Drinks","Drinks","Soft Drinks","Adult","Mixers","Soda Water"],
  ["Drinks","Drinks","Soft Drinks","Adult","Mixers","Other"],
  ["Drinks","Drinks","Soft Drinks","Adult","Alcohol Free","Alcohol Free Wine"],
  ["Drinks","Drinks","Soft Drinks","Adult","Alcohol Free","Alcohol Free Beer"],
  ["Drinks","Drinks","Soft Drinks","Adult","Alcohol Free","Alcohol Free Spirits"],
  ["Drinks","Drinks","Soft Drinks","Milks/ Alternatives","Ambient Dairy Milk","Whole"],
  ["Drinks","Drinks","Soft Drinks","Milks/ Alternatives","Ambient Dairy Milk","Semi skimmed"],
  ["Drinks","Drinks","Soft Drinks","Milks/ Alternatives","Ambient Dairy Milk","Skimmed"],
  ["Drinks","Drinks","Soft Drinks","Milks/ Alternatives","Plant Based Milks/ Drinks","Oat"],
  ["Drinks","Drinks","Soft Drinks","Milks/ Alternatives","Plant Based Milks/ Drinks","Soya"],
  ["Drinks","Drinks","Soft Drinks","Milks/ Alternatives","Plant Based Milks/ Drinks","Almond"],
  ["Drinks","Drinks","Soft Drinks","Milks/ Alternatives","Plant Based Milks/ Drinks","Other"],
  ["Drinks","Drinks","Soft Drinks","Milks/ Alternatives","Shakes","RTD"],
  ["Drinks","Drinks","Soft Drinks","Milks/ Alternatives","Shakes","Powders"],
  ["Drinks","Drinks","Soft Drinks","Water","Plain","Still"],
  ["Drinks","Drinks","Soft Drinks","Water","Plain","Sparkling"],
  ["Drinks","Drinks","Soft Drinks","Water","Flavoured","Still"],
  ["Drinks","Drinks","Soft Drinks","Water","Flavoured","Sparkling"],
  ["Food","Breakfast","Cereals","Everyday","Everyday","Cornflakes"],
  ["Food","Breakfast","Cereals","Everyday","Everyday","Chocolate"],
  ["Food","Breakfast","Cereals","Everyday","Everyday","Wheat"],
  ["Food","Breakfast","Cereals","Everyday","Everyday","Hoops"],
  ["Food","Breakfast","Cereals","Everyday","Everyday","Other flake"],
  ["Food","Breakfast","Cereals","Granola/ Muesli","Granola/ Muesli","Fruit Granola"],
  ["Food","Breakfast","Cereals","Granola/ Muesli","Granola/ Muesli","Chocolate Granola"],
  ["Food","Breakfast","Cereals","Granola/ Muesli","Granola/ Muesli","Nut Granola"],
  ["Food","Breakfast","Cereals","Granola/ Muesli","Granola/ Muesli","Muesli"],
  ["Food","Breakfast","Cereals","Porridge","Porridge","Oats"],
  ["Food","Breakfast","Cereals","Porridge","Porridge","Sachets"],
  ["Food","Breakfast","On The Go","On The Go","On The Go","Pots"],
  ["Food","Breakfast","On The Go","On The Go","On The Go","Breakfast Biscuits"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Potato Chips","Salted"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Potato Chips","Paprika"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Potato Chips","Cheese"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Potato Chips","Salt & Vinegar"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Potato Chips","Sour Cream"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Potato Chips","Other"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Tortilla Chips","Salted"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Tortilla Chips","Flavoured"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Maize/ Corn snacks","Salted"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Maize/ Corn snacks","Paprika"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Maize/ Corn snacks","Cheese"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Maize/ Corn snacks","Salt & Vinegar"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Maize/ Corn snacks","Sour Cream"],
  ["Food","Snacks","Chips & Savoury Snacks","Chips","Maize/ Corn snacks","Other"],
  ["Food","Snacks","Chips & Savoury Snacks","Other Savoury Snacks","Popcorn","Sweet"],
  ["Food","Snacks","Chips & Savoury Snacks","Other Savoury Snacks","Popcorn","Salty"],
  ["Food","Snacks","Chips & Savoury Snacks","Other Savoury Snacks","Popcorn","Sweet & Salty"],
  ["Food","Snacks","Chips & Savoury Snacks","Other Savoury Snacks","Popcorn","Flavoured"],
  ["Food","Snacks","Chips & Savoury Snacks","Other Savoury Snacks","Popcorn","Microwave"],
  ["Food","Snacks","Chips & Savoury Snacks","Other Savoury Snacks","Crackers","Plain"],
  ["Food","Snacks","Chips & Savoury Snacks","Other Savoury Snacks","Crackers","Flavoured"],
  ["Food","Snacks","Chips & Savoury Snacks","Other Savoury Snacks","Jerky/ Meat Snacks","Jerky/ Biltong"],
  ["Food","Snacks","Chips & Savoury Snacks","Other Savoury Snacks","Jerky/ Meat Snacks","Meat"],
  ["Food","Snacks","Chips & Savoury Snacks","Other Savoury Snacks","Jerky/ Meat Snacks","Pork Scratchings"],
  ["Food","Snacks","Fruit & Nut","Fruit","Raisins",""],
  ["Food","Snacks","Fruit & Nut","Fruit","Mango",""],
  ["Food","Snacks","Fruit & Nut","Fruit","Pineapple",""],
  ["Food","Snacks","Fruit & Nut","Fruit","Other",""],
  ["Food","Snacks","Fruit & Nut","Nuts","Almonds",""],
  ["Food","Snacks","Fruit & Nut","Nuts","Cashews",""],
  ["Food","Snacks","Fruit & Nut","Nuts","Pistachio",""],
  ["Food","Snacks","Fruit & Nut","Nuts","Walnut",""],
  ["Food","Snacks","Fruit & Nut","Nuts","Peanut",""],
  ["Food","Snacks","Fruit & Nut","Nuts","Mixed Nuts",""],
  ["Food","Snacks","Fruit & Nut","Mixed/ Trail","Mixed Fruit & Nut",""],
  ["Food","Snacks","Fruit & Nut","Mixed/ Trail","Trail Mix",""],
  ["Food","Snacks","Biscuits & Cakes","Biscuits","Sweet Biscuits","Plain"],
  ["Food","Snacks","Biscuits & Cakes","Biscuits","Sweet Biscuits","Chocolate"],
  ["Food","Snacks","Biscuits & Cakes","Biscuits","Sweet Biscuits","Wafers"],
  ["Food","Snacks","Biscuits & Cakes","Biscuits","Sweet Biscuits","Shortbread"],
  ["Food","Snacks","Biscuits & Cakes","Biscuits","Sweet Biscuits","Assorted"],
  ["Food","Snacks","Biscuits & Cakes","Biscuits","Cereal Bars","Treat Bars"],
  ["Food","Snacks","Biscuits & Cakes","Biscuits","Cereal Bars","Healthy Bars"],
  ["Food","Snacks","Biscuits & Cakes","Biscuits","Cereal Bars","Diet Bars"],
  ["Food","Snacks","Biscuits & Cakes","Cakes","Whole Cakes","Swiss Roll"],
  ["Food","Snacks","Biscuits & Cakes","Cakes","Whole Cakes","Loaf Cakes"],
  ["Food","Snacks","Biscuits & Cakes","Cakes","Whole Cakes","Other"],
  ["Food","Snacks","Biscuits & Cakes","Cakes","Cake Slices/ Small Cakes","Pies"],
  ["Food","Snacks","Biscuits & Cakes","Cakes","Cake Slices/ Small Cakes","Tarts"],
  ["Food","Snacks","Biscuits & Cakes","Cakes","Cake Slices/ Small Cakes","Cupcakes"],
  ["Food","Snacks","Biscuits & Cakes","Cakes","Cake Slices/ Small Cakes","Muffins"],
  ["Food","Snacks","Biscuits & Cakes","Cakes","Cake Slices/ Small Cakes","Mini cakes"],
  ["Food","Snacks","Biscuits & Cakes","Cakes","Cake Slices/ Small Cakes","Madeleines"],
  ["Food","Snacks","Biscuits & Cakes","Cakes","Flapjacks",""],
  ["Food","Snacks","Chocolate & Sweets","Chocolate","Chocolate Blocks","Milk"],
  ["Food","Snacks","Chocolate & Sweets","Chocolate","Chocolate Blocks","White"],
  ["Food","Snacks","Chocolate & Sweets","Chocolate","Chocolate Blocks","Dark"],
  ["Food","Snacks","Chocolate & Sweets","Chocolate","Chocolate Blocks","Flavoured"],
  ["Food","Snacks","Chocolate & Sweets","Chocolate","Chocolate Boxes/ Gifting",""],
  ["Food","Snacks","Chocolate & Sweets","Chocolate","Chocolate Pouches",""],
  ["Food","Snacks","Chocolate & Sweets","Chocolate","Chocolate Singles","Milk"],
  ["Food","Snacks","Chocolate & Sweets","Chocolate","Chocolate Singles","White"],
  ["Food","Snacks","Chocolate & Sweets","Chocolate","Chocolate Singles","Dark"],
  ["Food","Snacks","Chocolate & Sweets","Chocolate","Chocolate Singles","Flavoured"],
  ["Food","Snacks","Chocolate & Sweets","Sweets","Gummy Candies","Licquorice"],
  ["Food","Snacks","Chocolate & Sweets","Sweets","Gummy Candies","Fruit"],
  ["Food","Snacks","Chocolate & Sweets","Sweets","Gummy Candies","Sour"],
  ["Food","Snacks","Chocolate & Sweets","Sweets","Gummy Candies","Mochi"],
  ["Food","Snacks","Chocolate & Sweets","Sweets","Hard Boiled","Toffees"],
  ["Food","Snacks","Chocolate & Sweets","Sweets","Hard Boiled","Fruit"],
  ["Food","Snacks","Chocolate & Sweets","Sweets","Gum/ Mints","Chewing Gum"],
  ["Food","Snacks","Chocolate & Sweets","Sweets","Gum/ Mints","Mints"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Jam","Strawberry"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Jam","Raspberry"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Jam","Other Fruit"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Marmalade",""],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Nut Butter","Peanut Crunchy"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Nut Butter","Peanut Smooth"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Nut Butter","Almond Crunchy"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Nut Butter","Almond Smooth"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Nut Butter","Cashew Crunchy"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Nut Butter","Cashew Smooth"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Nut Butter","Other"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Chocolate Spread","Standard"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Chocolate Spread","Flavoured"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Honey/ Syrup","Honey"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Honey/ Syrup","Maple Syrup"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Honey/ Syrup","Golden Syrup"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Honey/ Syrup","Other"],
  ["Food","Pantry","Spreads & Desserts","Conserves/ Spreads","Yeast Extracts","Yeast"],
  ["Food","Pantry","Spreads & Desserts","Desserts","Compote/ Fruit Puree","Banana"],
  ["Food","Pantry","Spreads & Desserts","Desserts","Compote/ Fruit Puree","Apple"],
  ["Food","Pantry","Spreads & Desserts","Desserts","Compote/ Fruit Puree","Pear"],
  ["Food","Pantry","Spreads & Desserts","Desserts","Compote/ Fruit Puree","Berry"],
  ["Food","Pantry","Spreads & Desserts","Desserts","Compote/ Fruit Puree","Other"],
  ["Food","Pantry","Spreads & Desserts","Desserts","Rice Pudding",""],
  ["Food","Pantry","Spreads & Desserts","Desserts","Ice Cream Accompaniments","Ice Cream Sauce"],
  ["Food","Pantry","Spreads & Desserts","Desserts","Ice Cream Accompaniments","Wafers"],
  ["Food","Pantry","Spreads & Desserts","Desserts","Ice Cream Accompaniments","Cones"],
  ["Food","Pantry","Spreads & Desserts","Desserts","Jelly","RTE"],
  ["Food","Pantry","Spreads & Desserts","Desserts","Jelly","Powder/ Cubes"],
  ["Food","Pantry","Baking","Baking Ingredients","Flour","Plain"],
  ["Food","Pantry","Baking","Baking Ingredients","Flour","Self Raising"],
  ["Food","Pantry","Baking","Baking Ingredients","Flour","Other"],
  ["Food","Pantry","Baking","Baking Ingredients","Sugar/ Sweeteners","Brown"],
  ["Food","Pantry","Baking","Baking Ingredients","Sugar/ Sweeteners","White"],
  ["Food","Pantry","Baking","Baking Ingredients","Sugar/ Sweeteners","Sweetener"],
  ["Food","Pantry","Baking","Baking Ingredients","Baking Aids","Baking Powder"],
  ["Food","Pantry","Baking","Baking Ingredients","Baking Aids","Bicarbonate of Soda"],
  ["Food","Pantry","Baking","Baking Ingredients","Baking Aids","Other"],
  ["Food","Pantry","Baking","Baking Ingredients","Dried Fruit","Raisins"],
  ["Food","Pantry","Baking","Baking Ingredients","Dried Fruit","Citrus Peel"],
  ["Food","Pantry","Baking","Baking Ingredients","Dried Fruit","Cherries"],
  ["Food","Pantry","Baking","Baking Ingredients","Dried Fruit","Other/ Mixed"],
  ["Food","Pantry","Baking","Baking Ingredients","Decoration","Icing"],
  ["Food","Pantry","Baking","Baking Ingredients","Decoration","Sprinkles/ Decs"],
  ["Food","Pantry","Baking","Baking Mixes","Cake Mixes","Sponge Cake"],
  ["Food","Pantry","Baking","Baking Mixes","Cake Mixes","Brownie Mix"],
  ["Food","Pantry","Baking","Baking Mixes","Cake Mixes","Cooke Mix"],
  ["Food","Pantry","Baking","Baking Mixes","Cake Mixes","Other"],
  ["Food","Pantry","Baking","Baking Mixes","Dessert Mixes","Cheesecake"],
  ["Food","Pantry","Baking","Baking Mixes","Dessert Mixes","Other"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Stock Cubes/ Powder","Chicken"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Stock Cubes/ Powder","Beef"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Stock Cubes/ Powder","Vegetable"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Stock Cubes/ Powder","Other"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Gravy","Powder"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Gravy","Liquid"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Marinades","BBQ"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Marinades","Peri Peri"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Marinades","Chinese"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Marinades","Paprika"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Marinades","Other"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Cream","Bechamel"],
  ["Food","Pantry","Cooking Ingredients","Stock/ Marinades/ Gravy","Cream","Cream"],
  ["Food","Pantry","Cooking Ingredients","Herbs/ Spices","Herbs","Single Blend"],
  ["Food","Pantry","Cooking Ingredients","Herbs/ Spices","Herbs","Mixed"],
  ["Food","Pantry","Cooking Ingredients","Herbs/ Spices","Spices","Salt"],
  ["Food","Pantry","Cooking Ingredients","Herbs/ Spices","Spices","Pepper"],
  ["Food","Pantry","Cooking Ingredients","Herbs/ Spices","Spices","Chilli"],
  ["Food","Pantry","Cooking Ingredients","Herbs/ Spices","Spices","Mixed"],
  ["Food","Pantry","Cooking Ingredients","Herbs/ Spices","Spices","Other"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Pasta Sauce/ Italian","Bolognese"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Pasta Sauce/ Italian","Arrabiata"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Pasta Sauce/ Italian","Pesto"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Pasta Sauce/ Italian","Vegetable"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Pasta Sauce/ Italian","Creamy"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Pasta Sauce/ Italian","Other"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Indian","Korma"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Indian","Tikka Masala"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Indian","Jalfrezi"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Indian","Other"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Chinese","Sweet & Sour"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Chinese","Black Bean"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Chinese","Chinese Curry"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Chinese","Other"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Thai","Red"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Thai","Green"],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Mexican",""],
  ["Food","Pantry","Cooking Sauces","Ready to Pour","Other",""],
  ["Food","Pantry","Cooking Sauces","Pastes","Thai","Red"],
  ["Food","Pantry","Cooking Sauces","Pastes","Thai","Green"],
  ["Food","Pantry","Cooking Sauces","Pastes","Indian","Korma"],
  ["Food","Pantry","Cooking Sauces","Pastes","Indian","Tikka Masala"],
  ["Food","Pantry","Cooking Sauces","Pastes","Indian","Jalfrezi"],
  ["Food","Pantry","Cooking Sauces","Pastes","Indian","Other"],
  ["Food","Pantry","Cooking Sauces","Pastes","Other Cuisines",""],
  ["Food","Pantry","Meal Kits","Meal Kits","Mexican",""],
  ["Food","Pantry","Meal Kits","Meal Kits","Chinese",""],
  ["Food","Pantry","Meal Kits","Meal Kits","Japanese",""],
  ["Food","Pantry","Meal Kits","Meal Kits","Thai",""],
  ["Food","Pantry","Meal Kits","Meal Kits","Indian",""],
  ["Food","Pantry","Meal Kits","Meal Kits","Other Cuisines",""],
  ["Food","Pantry","Table Sauces & Condiments","Ketchup","Standard",""],
  ["Food","Pantry","Table Sauces & Condiments","Ketchup","Flavoured",""],
  ["Food","Pantry","Table Sauces & Condiments","Mayonnaise","Standard",""],
  ["Food","Pantry","Table Sauces & Condiments","Mayonnaise","Flavoured",""],
  ["Food","Pantry","Table Sauces & Condiments","Salad Cream","Standard",""],
  ["Food","Pantry","Table Sauces & Condiments","Salad Cream","Flavoured",""],
  ["Food","Pantry","Table Sauces & Condiments","Brown Sauces","Worcestershire",""],
  ["Food","Pantry","Table Sauces & Condiments","Brown Sauces","Brown",""],
  ["Food","Pantry","Table Sauces & Condiments","Chilli","Chilli",""],
  ["Food","Pantry","Table Sauces & Condiments","Chilli","Sweet Chilli",""],
  ["Food","Pantry","Table Sauces & Condiments","Mustard","English",""],
  ["Food","Pantry","Table Sauces & Condiments","Mustard","French",""],
  ["Food","Pantry","Table Sauces & Condiments","Mustard","American",""],
  ["Food","Pantry","Table Sauces & Condiments","Mustard","Wholegrain",""],
  ["Food","Pantry","Table Sauces & Condiments","Hummus/ Tapenade","Hummus",""],
  ["Food","Pantry","Table Sauces & Condiments","Hummus/ Tapenade","Tapenade",""],
  ["Food","Pantry","Table Sauces & Condiments","Hummus/ Tapenade","Guacamole",""],
  ["Food","Pantry","Table Sauces & Condiments","Soy Sauce","",""],
  ["Food","Pantry","Table Sauces & Condiments","Salsa","",""],
  ["Food","Pantry","Table Sauces & Condiments","BBQ","",""],
  ["Food","Pantry","Table Sauces & Condiments","Apple","",""],
  ["Food","Pantry","Table Sauces & Condiments","Cranberry","",""],
  ["Food","Pantry","Table Sauces & Condiments","Chutney","Mango",""],
  ["Food","Pantry","Table Sauces & Condiments","Chutney","Other",""],
  ["Food","Pantry","Table Sauces & Condiments","Other","",""],
  ["Food","Pantry","Pickles & Olives","Olives","Green",""],
  ["Food","Pantry","Pickles & Olives","Olives","Black",""],
  ["Food","Pantry","Pickles & Olives","Olives","Flavoured",""],
  ["Food","Pantry","Pickles & Olives","Pickles/ Veg","Gherkins",""],
  ["Food","Pantry","Pickles & Olives","Pickles/ Veg","Cornichons",""],
  ["Food","Pantry","Pickles & Olives","Pickles/ Veg","Cabbage",""],
  ["Food","Pantry","Pickles & Olives","Pickles/ Veg","Peppers",""],
  ["Food","Pantry","Pickles & Olives","Pickles/ Veg","Sun Dried Tomatoes",""],
  ["Food","Pantry","Pickles & Olives","Pickles/ Veg","Onions",""],
  ["Food","Pantry","Pickles & Olives","Pickles/ Veg","Other",""],
  ["Food","Pantry","Oils & Vinegars","Oils & Vinegars","Oil","Olive"],
  ["Food","Pantry","Oils & Vinegars","Oils & Vinegars","Oil","Other"],
  ["Food","Pantry","Oils & Vinegars","Oils & Vinegars","Vinegar","Malt"],
  ["Food","Pantry","Oils & Vinegars","Oils & Vinegars","Vinegar","Apple Cider"],
  ["Food","Pantry","Oils & Vinegars","Oils & Vinegars","Vinegar","Red Wine"],
  ["Food","Pantry","Oils & Vinegars","Oils & Vinegars","Vinegar","Balsamic"],
  ["Food","Pantry","Oils & Vinegars","Oils & Vinegars","Vinegar","Other"],
  ["Food","Pantry","Canned & Packet","Vegetables","Tomatoes","Passata"],
  ["Food","Pantry","Canned & Packet","Vegetables","Tomatoes","Chopped"],
  ["Food","Pantry","Canned & Packet","Vegetables","Tomatoes","Plum"],
  ["Food","Pantry","Canned & Packet","Vegetables","Sweetcorn",""],
  ["Food","Pantry","Canned & Packet","Vegetables","Other Vegetables","Carrots"],
  ["Food","Pantry","Canned & Packet","Vegetables","Other Vegetables","Mushrooms"],
  ["Food","Pantry","Canned & Packet","Vegetables","Other Vegetables","Peas"],
  ["Food","Pantry","Canned & Packet","Vegetables","Other Vegetables","Potatoes"],
  ["Food","Pantry","Canned & Packet","Vegetables","Other Vegetables","Green Beans"],
  ["Food","Pantry","Canned & Packet","Vegetables","Other Vegetables","Other"],
  ["Food","Pantry","Canned & Packet","Vegetables","Baked Beans","Standard"],
  ["Food","Pantry","Canned & Packet","Vegetables","Baked Beans","Flavoured"],
  ["Food","Pantry","Canned & Packet","Vegetables","Baked Beans","No Added Sugar"],
  ["Food","Pantry","Canned & Packet","Vegetables","Beans/ Pulses","Kidney Beans"],
  ["Food","Pantry","Canned & Packet","Vegetables","Beans/ Pulses","Back Beans"],
  ["Food","Pantry","Canned & Packet","Vegetables","Beans/ Pulses","Chickpeas"],
  ["Food","Pantry","Canned & Packet","Vegetables","Beans/ Pulses","Lentils"],
  ["Food","Pantry","Canned & Packet","Vegetables","Beans/ Pulses","Mixed"],
  ["Food","Pantry","Canned & Packet","Vegetables","Beans/ Pulses","Other"],
  ["Food","Pantry","Canned & Packet","Fruit","Cocktail/ Mixed","Syrup"],
  ["Food","Pantry","Canned & Packet","Fruit","Cocktail/ Mixed","Juice"],
  ["Food","Pantry","Canned & Packet","Fruit","Pineapple","Syrup"],
  ["Food","Pantry","Canned & Packet","Fruit","Pineapple","Juice"],
  ["Food","Pantry","Canned & Packet","Fruit","Peach/ Apricot","Syrup"],
  ["Food","Pantry","Canned & Packet","Fruit","Peach/ Apricot","Juice"],
  ["Food","Pantry","Canned & Packet","Fruit","Pear","Syrup"],
  ["Food","Pantry","Canned & Packet","Fruit","Pear","Juice"],
  ["Food","Pantry","Canned & Packet","Fruit","Other","Syrup"],
  ["Food","Pantry","Canned & Packet","Fruit","Other","Juice"],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Ham",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Hot Dogs",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Corned Beef",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Pate",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Charcuterie",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Other Meat",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Tuna","Oil"],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Tuna","Water"],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Tuna","Brine"],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Salmon",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Other Fish",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Tofu",""],
  ["Food","Pantry","Canned & Packet","Pasta","Spaghetti Hoops",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Character Shaped",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Ravioli",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Macaroni Cheese",""],
  ["Food","Pantry","Canned & Packet","Meat/ Fish/ Alternatives","Other",""],
  ["Food","Pantry","Canned & Packet","Soup","Canned Soup","Tomato"],
  ["Food","Pantry","Canned & Packet","Soup","Canned Soup","Chicken"],
  ["Food","Pantry","Canned & Packet","Soup","Canned Soup","Vegetable"],
  ["Food","Pantry","Canned & Packet","Soup","Canned Soup","Other"],
  ["Food","Pantry","Canned & Packet","Soup","Soup Mix","Tomato"],
  ["Food","Pantry","Canned & Packet","Soup","Soup Mix","Chicken"],
  ["Food","Pantry","Canned & Packet","Soup","Soup Mix","Vegetable"],
  ["Food","Pantry","Canned & Packet","Soup","Soup Mix","Other"],
  ["Food","Pantry","Canned & Packet","Soup","Cup Soup","Tomato"],
  ["Food","Pantry","Canned & Packet","Soup","Cup Soup","Chicken"],
  ["Food","Pantry","Canned & Packet","Soup","Cup Soup","Vegetable"],
  ["Food","Pantry","Canned & Packet","Soup","Cup Soup","Other"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Rice","Cooking Rice","Basmati"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Rice","Cooking Rice","Wholegrain"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Rice","Cooking Rice","Jasmine"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Rice","Cooking Rice","Wild/ Brown"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Rice","Cooking Rice","Other"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Rice","Cooking Rice","Pudding"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Rice","Microwave","White"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Rice","Microwave","Wholegrain"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Rice","Microwave","Mixed/ Flavoured"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Pasta","Pasta Shapes","Wholewheat"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Pasta","Pasta Shapes","Wheat"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Pasta","Spaghetti","Wholewheat"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Pasta","Spaghetti","Wheat"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Pasta","Lasagne","Wholewheat"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Pasta","Lasagne","Wheat"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Noodles","Straight to Wok","Udon"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Noodles","Straight to Wok","Egg"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Noodles","Straight to Wok","Rice"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Noodles","Dried Noodles","Egg"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Noodles","Dried Noodles","Rice"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Noodles","Dried Noodles","Wholewheat"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Noodles","Dried Noodles","Other"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Grains/ Pulses","Cous cous","Wheat"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Grains/ Pulses","Cous cous","Wholewheat"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Grains/ Pulses","Quinoa",""],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Grains/ Pulses","Lentils","Green/ Puy"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Grains/ Pulses","Lentils","Red"],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Grains/ Pulses","Other Grains",""],
  ["Food","Pantry","Dried Rice/ Pasta/ Noodles/ Pulses","Grains/ Pulses","Beans",""],
  ["Food","Pantry","Instant Meals","Noodles","Packets","Chicken"],
  ["Food","Pantry","Instant Meals","Noodles","Packets","Vegetable"],
  ["Food","Pantry","Instant Meals","Noodles","Packets","Other"],
  ["Food","Pantry","Instant Meals","Noodles","Pots","Chicken"],
  ["Food","Pantry","Instant Meals","Noodles","Pots","Vegetable"],
  ["Food","Pantry","Instant Meals","Noodles","Pots","Other"],
  ["Food","Pantry","Instant Meals","Grain/ Lentils","Lentil Based Meals",""],
  ["Food","Pantry","Instant Meals","Grain/ Lentils","Grain Based Meals",""],
  ["Food","Pantry","Instant Meals","Grain/ Lentils","Bean Based Meals",""],
  ["Food","Pantry","Instant Meals","Pasta","Packet/ Dehydrated",""],
  ["Food","Pantry","Instant Meals","Pasta","Microwave/ Pots",""],
  ["Food","Pantry","Bakery & Bread","Bread","Toast Bread","Wholemeal"],
  ["Food","Pantry","Bakery & Bread","Bread","Toast Bread","White"],
  ["Food","Pantry","Bakery & Bread","Bread","Wraps","Wholemeal"],
  ["Food","Pantry","Bakery & Bread","Bread","Wraps","White"],
  ["Food","Pantry","Bakery & Bread","Bread","Sweet Bread","Pannetone"],
  ["Food","Pantry","Bakery & Bread","Bread","Sweet Bread","Brioche"],
  ["Food","Pantry","Bakery & Bread","Bread","Rolls","Wholemeal"],
  ["Food","Pantry","Bakery & Bread","Bread","Rolls","White"],
  ["Food","Pantry","Bakery & Bread","Bread","Pizza Bases",""],
  ["Food","Pantry","Bakery & Bread","Sweet Pastry","Pastries",""],
  ["Food","Pantry","Bakery & Bread","Sweet Pastry","Waffles",""],
  ["Food","Pantry","Bakery & Bread","Sweet Pastry","Other",""],
  ["Food","Health","Health & Well Being","Vitamins","Kids",""],
  ["Food","Health","Health & Well Being","Vitamins","Female Specific",""],
  ["Food","Health","Health & Well Being","Vitamins","Sleep",""],
  ["Food","Health","Health & Well Being","Vitamins","Other",""],
  ["Food","Health","Health & Well Being","Protein","Powder",""],
  ["Food","Health","Health & Well Being","Protein","Shakes",""],
  ["Food","Health","Health & Well Being","Hemp","",""],
  ["Food","Health","Health & Well Being","Sports/ Energy","Drinks",""],
  ["Food","Health","Health & Well Being","Sports/ Energy","Gels/ Capsules",""],
  ["Food","Health","Health & Well Being","Sports/ Energy","Other",""],
  ["Pet Food","Pet Food","Cat Food","Dry Food","Kitten",""],
  ["Pet Food","Pet Food","Cat Food","Dry Food","Adult",""],
  ["Pet Food","Pet Food","Cat Food","Dry Food","Senior",""],
  ["Pet Food","Pet Food","Cat Food","Dry Food","Dietary",""],
  ["Pet Food","Pet Food","Cat Food","Wet Food","Kitten",""],
  ["Pet Food","Pet Food","Cat Food","Wet Food","Adult",""],
  ["Pet Food","Pet Food","Cat Food","Wet Food","Senior",""],
  ["Pet Food","Pet Food","Cat Food","Wet Food","Dietary",""],
  ["Pet Food","Pet Food","Cat Food","Treats","Dental",""],
  ["Pet Food","Pet Food","Cat Food","Treats","Training",""],
  ["Pet Food","Pet Food","Dog Food","Dry Food","Puppy",""],
  ["Pet Food","Pet Food","Dog Food","Dry Food","Adult",""],
  ["Pet Food","Pet Food","Dog Food","Dry Food","Senior",""],
  ["Pet Food","Pet Food","Dog Food","Dry Food","Dietary",""],
  ["Pet Food","Pet Food","Dog Food","Wet Food","Puppy",""],
  ["Pet Food","Pet Food","Dog Food","Wet Food","Adult",""],
  ["Pet Food","Pet Food","Dog Food","Wet Food","Senior",""],
  ["Pet Food","Pet Food","Dog Food","Wet Food","Dietary",""],
  ["Pet Food","Pet Food","Dog Food","Treats","Dental",""],
  ["Pet Food","Pet Food","Dog Food","Treats","Training",""],
  ["Food","Baby & Toddler","Baby & Toddler","Milk","",""],
  ["Food","Baby & Toddler","Baby & Toddler","Drinks","",""],
  ["Food","Baby & Toddler","Baby & Toddler","<1year food","Meals","6m+"],
  ["Food","Baby & Toddler","Baby & Toddler","<1year food","Meals","10m+"],
  ["Food","Baby & Toddler","Baby & Toddler",">1 year food","Meals","12m+"],
  ["Food","Baby & Toddler","Baby & Toddler",">1 year food","Snacks","12m+"],
  ["Non Food","Household Essentials","Cleaning Supplies","Kitchen","All Purpose Spray",""],
  ["Non Food","Household Essentials","Cleaning Supplies","Kitchen","Hob/ Oven Cleaer",""],
  ["Non Food","Household Essentials","Cleaning Supplies","Kitchen","Dishwasher",""],
  ["Non Food","Household Essentials","Cleaning Supplies","Kitchen","Floor Cleaner",""],
  ["Non Food","Household Essentials","Cleaning Supplies","Bathroom","Bathroom Cleaners",""],
  ["Non Food","Household Essentials","Cleaning Supplies","Bathroom","Toilet",""],
  ["Non Food","Household Essentials","Cleaning Supplies","Bathroom","Limescale Remover",""],
  ["Non Food","Household Essentials","Cleaning Supplies","Tools","Washing Up Brushes",""],
  ["Non Food","Household Essentials","Cleaning Supplies","Tools","Sponges/ Scourers",""],
  ["Non Food","Household Essentials","Cleaning Supplies","Tools","Dustpan & Brush",""],
  ["Non Food","Household Essentials","Cleaning Supplies","Tools","Cloths",""],
  ["Non Food","Household Essentials","Laundry","Detergent","Capsules/ Pods","Bio"],
  ["Non Food","Household Essentials","Laundry","Detergent","Capsules/ Pods","Non Bio"],
  ["Non Food","Household Essentials","Laundry","Detergent","Powder","Bio"],
  ["Non Food","Household Essentials","Laundry","Detergent","Powder","Non Bio"],
  ["Non Food","Household Essentials","Laundry","Detergent","Gel","Bio"],
  ["Non Food","Household Essentials","Laundry","Detergent","Gel","Non Bio"],
  ["Non Food","Household Essentials","Laundry","Additives","Additives","Fabric Conditioner"],
  ["Non Food","Household Essentials","Laundry","Additives","Additives","Scent Boosters"],
  ["Non Food","Household Essentials","Laundry","Additives","Additives","Stain Remover"],
  ["Non Food","Household Essentials","Laundry","Additives","Additives","Tumble Dryer Sheets"],
  ["Non Food","Household Essentials","Air Care","Candles","",""],
  ["Non Food","Household Essentials","Air Care","Diffusers/ Incense","",""],
  ["Non Food","Household Essentials","Air Care","Plug in/ Refills","",""],
  ["Non Food","Household Essentials","Air Care","Gel/ Blocks","Car",""],
  ["Non Food","Household Essentials","Air Care","Gel/ Blocks","House",""],
  ["Non Food","Household Essentials","Air Care","Aerosols","Bathroom",""],
  ["Non Food","Household Essentials","Air Care","Aerosols","Odour Control",""],
  ["Non Food","Household Essentials","Air Care","Aerosols","Other",""],
  ["Non Food","Household Essentials","Paper","Kitchen Roll","Kitchen Roll",""],
  ["Non Food","Household Essentials","Paper","Toilet Roll","Toilet Roll",""],
  ["Non Food","Household Essentials","Paper","Tissues","Tissue Boxes",""],
  ["Non Food","Household Essentials","Paper","Tissues","Pocket Tissues",""],
  ["Non Food","Household Essentials","Paper","Wipes","Hand Wipes",""],
  ["Non Food","Household Essentials","Storage & Disposables","Trash Bags","Trash Bags",""],
  ["Non Food","Household Essentials","Storage & Disposables","Food Storage","Food Storage Bags",""],
  ["Non Food","Household Essentials","Storage & Disposables","Food Storage","Food Storage Containers",""],
  ["Non Food","Baby Essentials","Diapers","Size 0, 1 & 2","",""],
  ["Non Food","Baby Essentials","Diapers","Size 3-5","",""],
  ["Non Food","Baby Essentials","Diapers","Size 6+","",""],
  ["Non Food","Baby Essentials","Wipes","Fragranced","",""],
  ["Non Food","Baby Essentials","Wipes","Non Fragranced","",""],
  ["Non Food","Personal Hygiene","Body Wash","Shower Gel","",""],
  ["Non Food","Personal Hygiene","Body Wash","Bath Foam","",""],
  ["Non Food","Personal Hygiene","Female Hygiene","Sanitary napkins and liners","",""],
  ["Non Food","Personal Hygiene","Female Hygiene","Tampons","",""],
  ["Non Food","Personal Hygiene","Hand Wash","Liquid Hand Wash","",""],
  ["Non Food","Personal Hygiene","Hand Wash","Soap","",""],
  ["Non Food","Personal Hygiene","Deodorant","Roll On","Male",""],
  ["Non Food","Personal Hygiene","Deodorant","Roll On","Female",""],
  ["Non Food","Personal Hygiene","Deodorant","Roll On","Unisex",""],
  ["Non Food","Personal Hygiene","Deodorant","Spray","Male",""],
  ["Non Food","Personal Hygiene","Deodorant","Spray","Female",""],
  ["Non Food","Personal Hygiene","Deodorant","Spray","Unisex",""],
  ["Non Food","Personal Hygiene","Deodorant","Stick","Male",""],
  ["Non Food","Personal Hygiene","Deodorant","Stick","Female",""],
  ["Non Food","Personal Hygiene","Deodorant","Stick","Unisex",""],
  ["Non Food","Personal Hygiene","Oral care","Toothpaste","Kids",""],
  ["Non Food","Personal Hygiene","Oral care","Toothpaste","Adult",""],
  ["Non Food","Personal Hygiene","Oral care","Toothbrushes","Kids",""],
  ["Non Food","Personal Hygiene","Oral care","Toothbrushes","Adult",""],
  ["Non Food","Personal Hygiene","Oral care","Mouthwash","",""],
  ["Non Food","Personal Hygiene","Oral care","Floss","",""],
  ["Non Food","Personal Hygiene","Hair care","Shampoo","Normal",""],
  ["Non Food","Personal Hygiene","Hair care","Shampoo","Dry/ Damaged",""],
  ["Non Food","Personal Hygiene","Hair care","Shampoo","Colour Care",""],
  ["Non Food","Personal Hygiene","Hair care","Shampoo","Curly",""],
  ["Non Food","Personal Hygiene","Hair care","Shampoo","Kids",""],
  ["Non Food","Personal Hygiene","Hair care","Shampoo","Mens",""],
  ["Non Food","Personal Hygiene","Hair care","Shampoo","Dandruff",""],
  ["Non Food","Personal Hygiene","Hair care","Conditioner","Normal",""],
  ["Non Food","Personal Hygiene","Hair care","Conditioner","Dry/ Damaged",""],
  ["Non Food","Personal Hygiene","Hair care","Conditioner","Colour Care",""],
  ["Non Food","Personal Hygiene","Hair care","Conditioner","Curly",""],
  ["Non Food","Personal Hygiene","Hair care","Conditioner","Kids",""],
  ["Non Food","Personal Hygiene","Hair care","Conditioner","Mens",""],
  ["Non Food","Personal Hygiene","Hair care","Treatments & Oils","",""],
  ["Non Food","Personal Hygiene","First aid","Band Aids","",""],
  ["Non Food","Skin Care","Facial cleansers & toners","Cleansers","",""],
  ["Non Food","Skin Care","Facial cleansers & toners","Toners","",""],
  ["Non Food","Skin Care","Facial cleansers & toners","Wipes","",""],
  ["Non Food","Skin Care","Moisturizers & creams","Body Lotion","",""],
  ["Non Food","Skin Care","Moisturizers & creams","Hand Lotion","",""],
  ["Non Food","Skin Care","Sunscreen & sun care","Sunscreen","SPF30",""],
  ["Non Food","Skin Care","Sunscreen & sun care","Sunscreen","SPF50",""],
  ["Non Food","Skin Care","Sunscreen & sun care","Sunscreen","Kids/ Sensitive",""],
  ["Non Food","Skin Care","Sunscreen & sun care","Sunscreen","Other",""],
  ["Non Food","Skin Care","Specialised","Acne/ Blemish Care","",""],
  ["Non Food","Skin Care","Specialised","Anti- Aging","",""],
  ["Non Food","Beauty","Beauty tools","Brushes","",""],
  ["Non Food","Beauty","Beauty tools","Sponges","",""],
  ["Non Food","Beauty","Beauty tools","Mirrors","",""],
  ["Non Food","Beauty","Eyes","Eyebrow","",""],
  ["Non Food","Beauty","Eyes","Eyeliner","",""],
  ["Non Food","Beauty","Eyes","Eyelashes","",""],
  ["Non Food","Beauty","Eyes","Other","",""],
  ["Non Food","Beauty","Lips","Lip Balm","",""],
  ["Non Food","Beauty","Lips","Lipstick","",""],
  ["Non Food","Beauty","Lips","Lip Gloss","",""],
  ["Non Food","Beauty","Face","Foundation","",""],
  ["Non Food","Beauty","Face","Concealer","",""],
  ["Non Food","Beauty","Face","Primer","",""],
  ["Non Food","Beauty","Face","Other","",""],
  ["Non Food","Beauty","Nails","Nail Varnish","",""],
  ["Non Food","Beauty","Nails","Nail Varnish Remover","",""],
  ["Non Food","Fragrance","Mens","","",""],
  ["Non Food","Fragrance","Womens","","",""]
].freeze

class MasterDataHunter
  include HTTParty

  def initialize
    @headers = { 'Content-Type' => 'application/json' }

    @country_langs = {
      "DE" => "German", "AT" => "German", "CH" => "German",
      "UK" => "English", "GB" => "English", "FR" => "French",
      "IT" => "Italian", "ES" => "Spanish", "NL" => "Dutch",
      "DK" => "Danish", "SE" => "Swedish", "NO" => "Norwegian",
      "PL" => "Polish", "PT" => "Portuguese", "FI" => "Finnish",
      "BE" => "German, French, AND Dutch (Must provide all 3)"
    }

    @hl_codes = {
      "DE" => "de", "AT" => "de", "CH" => "de", "UK" => "en", "GB" => "en",
      "FR" => "fr", "IT" => "it", "ES" => "es", "NL" => "nl", "BE" => "nl",
      "DK" => "da", "SE" => "sv", "NO" => "no", "PL" => "pl", "PT" => "pt", "FI" => "fi"
    }

    @local_search_terms = {
      "FR" => "ingrédients nutrition", "IT" => "ingredienti nutrizionali", "ES" => "ingredientes nutrición",
      "NL" => "ingrediënten voedingswaarde", "DK" => "ingredienser næringsindhold", "SE" => "ingredienser näringsvärde",
      "NO" => "ingredienser næringsinnhold", "FI" => "ainesosat ravintosisältö", "PL" => "składniki wartości odżywcze",
      "DE" => "zutaten nährwerte", "AT" => "zutaten nährwerte", "CH" => "zutaten nährwerte",
      "BE" => "ingrédients ingrediënten", "UK" => "ingredients nutrition", "PT" => "ingredientes nutrição"
    }

    @country_names = {
      "DE" => "Deutschland Germany", "AT" => "Österreich Austria", "CH" => "Schweiz Switzerland",
      "UK" => "UK United Kingdom", "GB" => "UK United Kingdom", "FR" => "France",
      "IT" => "Italia Italy", "ES" => "España Spain", "PL" => "Polska Poland",
      "DK" => "Danmark Denmark", "NL" => "Nederland Netherlands", "BE" => "Belgique België Belgium",
      "SE" => "Sverige Sweden", "NO" => "Norge Norway", "PT" => "Portugal", "FI" => "Suomi Finland"
    }

    @goldmine_sites = {
      "FR" => "site:carrefour.fr OR site:auchan.fr OR site:coursesu.com",
      "UK" => "site:ocado.com OR site:waitrose.com OR site:asda.com OR site:tesco.com",
      "NL" => "site:ah.nl OR site:jumbo.com OR site:plus.nl",
      "BE" => "site:delhaize.be OR site:colruyt.be OR site:carrefour.be",
      "DE" => "site:rewe.de OR site:edeka.de OR site:kaufland.de OR site:dm.de OR site:rossmann.de",
      "AT" => "site:billa.at OR site:spar.at OR site:gurkerl.at OR site:hofer.at",
      "DK" => "site:nemlig.com OR site:matsmart.dk OR site:rema1000.dk",
      "IT" => "site:carrefour.it OR site:conad.it OR site:coop.it",
      "ES" => "site:carrefour.es OR site:mercadona.es OR site:dia.es",
      "SE" => "site:ica.se OR site:coop.se OR site:willys.se",
      "NO" => "site:oda.com OR site:meny.no OR site:holdbart.no",
      "FI" => "site:k-ruoka.fi OR site:s-kaupat.fi",
      "PL" => "site:carrefour.pl OR site:auchan.pl OR site:frisco.pl"
    }
    global_sites = "site:billigkaffee.eu OR site:fivestartrading-holland.eu"
    @goldmine_sites.each { |m, s| @goldmine_sites[m] = "#{s} OR #{global_sites}" }
    @goldmine_sites.default = global_sites
  end

  def process_product(gtin, market)
    return { found: false, status: "Missing GEMINI_API_KEY" } if GEMINI_API_KEY.nil? || GEMINI_API_KEY.empty?

    confirmed_sources = []
    is_deep_search = false

    # STEP 1: REGISTRY
    official_data = fetch_official_ean_data(gtin)
    registry_name = official_data ? official_data['name'] : nil
    if official_data
      confirmed_sources << { type: "registry", title: "Official Registry", url: "https://www.ean-search.org/?q=#{gtin}" }
    end

    # STEP 2: PARALLEL SEARCH — all searches run simultaneously, no waterfall
    threads = []
    retailer_results = []
    deep_results = []
    off_text = ""

    threads << Thread.new { retailer_results = find_retailer_urls(gtin, market) }

    threads << Thread.new do
      search_name = registry_name || infer_name_from_ean(gtin, market)
      deep_results = search_name ? find_deep_urls(search_name, market) : find_retailer_urls(gtin, market)
    end

    threads << Thread.new { off_text = fetch_openfoodfacts(gtin) }

    image_results = [nil, nil]
    image_thread = Thread.new { image_results = find_three_images(gtin, market, official_data) }

    deadline = Time.now + 45
    image_deadline = Time.now + 30
    image_thread.join([image_deadline - Time.now, 0.5].max) if image_thread.alive?
    threads.each { |t| t.join([deadline - Time.now, 0.1].max) }
    (threads + [image_thread]).each { |t| t.kill if t.alive? }

    all_urls = (retailer_results + deep_results).uniq.first(12)

    # STEP 3: SCRAPING
    web_data = fetch_parallel_page_data(all_urls)
    web_data[:valid_urls].each { |u| confirmed_sources << { type: "web", title: host_from_url(u), url: u } }

    image_results.compact.each_with_index do |img, i|
      confirmed_sources << { type: "image", title: "Image #{i+1}", url: img[:url] } if img
    end

    primary_image = image_results.find { |i| i && i[:base64] }

    if primary_image.nil? && web_data[:text].strip.empty? && off_text.empty?
      return empty_result(gtin, market, "No Data Found (Blind)", nil)
    end

    final_name_context = official_data || { 'name' => registry_name }

    # Image domain confidence check
    image_confidence_note = nil
    if primary_image && web_data[:valid_urls].any?
      image_host = URI.parse(primary_image[:url]).host.sub(/^www\./, '') rescue nil
      web_hosts = web_data[:valid_urls].map { |u| URI.parse(u).host.sub(/^www\./, '') rescue nil }.compact
      unless web_hosts.any? { |h| h.include?(image_host.to_s.split('.').first) }
        image_confidence_note = "NOTE: Image source domain differs from web sources. Prefer text data if they conflict."
      end
    end

    # Combine all text — OFF data prepended as high-quality structured source
    combined_input = ""
    combined_input += "=== OPENFOODFACTS DATA ===\n#{off_text}\n\n" unless off_text.empty?
    combined_input += web_data[:text]

    # Relevance check — only warn if truly mismatched
    relevant_text = combined_input
    if web_data[:text].length > 100 && registry_name
      name_words = registry_name.downcase.split(" ").reject { |w| w.length < 4 }
      gtin_found = web_data[:text].include?(gtin)
      name_found = name_words.any? { |w| web_data[:text].downcase.include?(w) }
      unless gtin_found || name_found || name_words.empty?
        relevant_text = "WARNING: Web sources may not match this specific product. Cross-reference carefully.\n\n" + combined_input
      end
    end

    # STEP 4: AI ANALYSIS
    ai_result = analyze_with_gemini(primary_image, relevant_text, final_name_context, gtin, market, image_confidence_note)

    ai_hash = {}
    if ai_result.is_a?(Hash)
      ALLOWED_KEYS.each { |k| ai_hash[k] = ai_result[k] if ai_result.key?(k) }
      ai_hash["error"] = ai_result["error"] if ai_result["error"]
    end

    return empty_result(gtin, market, ai_hash["error"], nil) if ai_hash["error"]

    # STEP 5: FALLBACK ESCALATION — triggers on missing nutrition OR missing ingredients
    ing_text = ai_hash["ingredients"].to_s.downcase
    missing_phrases = %w[keine not\ found unavailable inconnu nicht\ verfügbar none
      no\ encontrado niet\ gevonden ikke\ fundet hittades\ inte brak ei\ löydy non\ trovato]

    nutrition_fields = %w[energy_kj fat saturates carbs sugars protein salt]
    is_empty_val = ->(v) {
      s = v.to_s.strip.downcase
      s.empty? || s == "-" || s == "null" || s.include?("not") || s.include?("n/a")
    }
    nutrition_missing = nutrition_fields.count { |f| is_empty_val.call(ai_hash[f]) }

    if ing_text.length < 10 || missing_phrases.any? { |p| ing_text.include?(p) } || nutrition_missing >= 5
      log("Fallback Escalation for #{gtin}: nutrition #{nutrition_missing}/7 empty, ing length #{ing_text.length}")
      search_name = ai_hash["product_name"] || registry_name || infer_name_from_ean(gtin, market)

      if search_name && search_name.length > 3
        fallback_urls = find_deep_urls(search_name, market)
        if fallback_urls.any?
          fallback_data = fetch_parallel_page_data(fallback_urls)
          if fallback_data[:text].length > 200
            is_deep_search = true
            combined2 = relevant_text + "\n\n=== FALLBACK SEARCH ===\n" + fallback_data[:text]
            fallback_data[:valid_urls].each { |u| confirmed_sources << { type: "rescue", title: host_from_url(u), url: u } }
            ai2 = analyze_with_gemini(primary_image, combined2, final_name_context, gtin, market, image_confidence_note)
            if ai2.is_a?(Hash) && !ai2["error"]
              ALLOWED_KEYS.each do |k|
                next unless ai2.key?(k)
                new_v = ai2[k].to_s.strip
                old_v = ai_hash[k].to_s.strip
                ai_hash[k] = ai2[k] if is_empty_val.call(old_v) || (!is_empty_val.call(new_v) && new_v.length > old_v.length)
              end
            end
          end
        end
      end
    end

    # Build display images — 2 images: pack shot + single product
    display_images = image_results.map do |img|
      next nil unless img
      if img[:base64] && img[:mime]
        "data:#{img[:mime]};base64,#{img[:base64]}"
      else
        img[:url]
      end
    end

    has_registry = !!official_data
    has_image    = image_results.any? { |i| i && i[:base64] }
    has_web      = web_data[:valid_urls].any? && web_data[:text].length > 200

    status = if is_deep_search then "Found (Deep Search)"
             elsif has_registry && has_web && has_image then "Found (Registry+Web+Image)"
             elsif has_web && has_image then "Found (Web+Image)"
             elsif has_web then "Found (Web)"
             elsif has_image && has_registry then "Found (Registry+Image)"
             elsif has_image then "Found (Image)"
             elsif has_registry then "Registry Only"
             else "Blind"
             end

    {
      found: true, gtin: gtin, status: status, market: market,
      image_url:  display_images[0],
      image_url2: display_images[1],
      issuing_country: official_data ? official_data['issuingCountry'] : nil,
      defined_sources: confirmed_sources.uniq { |s| s[:url] }
    }.merge(ai_hash)
  end

  private

  def log(msg) = STDERR.puts("[#{Time.now.utc.iso8601}] #{msg}")
  def host_from_url(url) = URI.parse(url).host.sub(/^www\./, '') rescue "Link"

  def mime_from_fastimage(type)
    { jpeg: "image/jpeg", jpg: "image/jpeg", png: "image/png", webp: "image/webp",
      heic: "image/heic", heif: "image/heif", avif: "image/avif",
      bmp: "image/bmp", gif: "image/gif" }[type]
  end

  def is_clean_url?(url)
    return false if url.nil? || url.empty?
    path = URI.parse(url).path.downcase rescue url.downcase
    !BAD_URL_PATTERNS.any? { |p| url.downcase.include?(p) || path.end_with?(p) }
  end

  def infer_name_from_ean(gtin, market)
    return nil if SERPAPI_KEY.nil?
    gl = market == "UK" ? "gb" : market.downcase
    begin
      res = Timeout.timeout(15) { GoogleSearch.new(q: gtin, gl: gl, num: 3, api_key: SERPAPI_KEY).get_hash }
      first = (res[:organic_results] || []).first
      return first[:title].split(/ [|\-] /).first.strip if first
    rescue => e; log("Name inference error: #{e.message}") end
    nil
  end

  def fetch_openfoodfacts(gtin)
    begin
      resp = Timeout.timeout(6) {
        HTTParty.get("https://world.openfoodfacts.org/api/v2/product/#{gtin}.json",
          headers: { "User-Agent" => "TGTGHunter/4.5 (contact@toogoodtogo.com)" }, timeout: 5)
      }
      return "" unless resp.code == 200
      data = JSON.parse(resp.body)
      return "" unless data["status"] == 1
      p = data["product"] || {}
      n = p["nutriments"] || {}
      parts = []
      parts << "OFF Product: #{p['product_name']}" if p['product_name']
      parts << "OFF Brand: #{p['brands']}" if p['brands']
      parts << "OFF Ingredients: #{p['ingredients_text']}" if p['ingredients_text']
      parts << "OFF Allergens: #{p['allergens']}" if p['allergens']
      parts << "OFF Quantity: #{p['quantity']}" if p['quantity']
      parts << "OFF Countries: #{p['countries']}" if p['countries']
      parts << "OFF Packaging: #{p['packaging']}" if p['packaging']
      parts << "OFF Labels: #{p['labels']}" if p['labels']
      parts << "OFF Manufacturer: #{p['manufacturing_places']}" if p['manufacturing_places']
      parts << "OFF Origins: #{p['origins']}" if p['origins']
      nutr = []
      { 'energy-kj_100g' => 'Energy kJ/100g', 'fat_100g' => 'Fat/100g',
        'saturated-fat_100g' => 'Saturates/100g', 'carbohydrates_100g' => 'Carbs/100g',
        'sugars_100g' => 'Sugars/100g', 'proteins_100g' => 'Protein/100g',
        'fiber_100g' => 'Fiber/100g', 'salt_100g' => 'Salt/100g' }.each do |k, label|
        nutr << "#{label}: #{n[k]}" if n[k]
      end
      parts << "OFF Nutrition per 100g: #{nutr.join(', ')}" unless nutr.empty?
      parts.join("\n")
    rescue => e
      log("OFF error #{gtin}: #{e.message}")
      ""
    end
  end

  def find_retailer_urls(gtin, market)
    return [] if SERPAPI_KEY.nil?
    gl = market == "UK" ? "gb" : market.downcase
    goldmine = @goldmine_sites[market]
    return [] unless goldmine
    urls = []
    begin
      res = Timeout.timeout(15) { GoogleSearch.new(q: "#{goldmine} #{gtin}", gl: gl, num: 8, api_key: SERPAPI_KEY).get_hash }
      (res[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
    rescue => e; log("Retailer search error: #{e.message}") end
    urls
  end

  def find_deep_urls(name, market)
    return [] if name.nil? || name.length < 3
    gl = market == "UK" ? "gb" : market.downcase
    bans = "-site:pinterest.com -site:tiktok.com -site:facebook.com -site:instagram.com"
    clean = name.gsub(/[^a-zA-Z0-9\s]/, '').gsub(/\s+/, ' ').strip
    short = clean.split(' ')[0..3].join(" ")
    local_terms = @local_search_terms[market] || "ingredients nutrition"
    goldmine = @goldmine_sites[market]

    urls = []
    begin
      # Broad brand/manufacturer search — no restrictions, finds official sites
      r1 = Timeout.timeout(15) { GoogleSearch.new(q: "\"#{short}\" ingredients nutrition #{bans}", gl: gl, num: 6, api_key: SERPAPI_KEY).get_hash }
      (r1[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }

      # Goldmine retailer search for local market data
      if goldmine && urls.length < 4
        r2 = Timeout.timeout(15) { GoogleSearch.new(q: "#{goldmine} \"#{short}\" #{local_terms} #{bans}", gl: gl, num: 6, api_key: SERPAPI_KEY).get_hash }
        (r2[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
      end

      # Fully open global search if still thin
      if urls.length < 3
        r3 = Timeout.timeout(15) { GoogleSearch.new(q: "#{short} #{local_terms} barcode #{bans}", num: 6, api_key: SERPAPI_KEY).get_hash }
        (r3[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
      end

      # Non-food fallback
      if urls.empty?
        log("Non-food bypass for: #{short}")
        r4 = Timeout.timeout(15) { GoogleSearch.new(q: "site:zooplus.com OR site:idealo.de OR site:bol.com #{short}", num: 6, api_key: SERPAPI_KEY).get_hash }
        (r4[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
      end
    rescue => e; log("Deep search error: #{e.message}") end
    urls.uniq.first(8)
  end

  # THREE IMAGES: pack shot, lifestyle/serving, nutrition label
  # Returns [image1, image2] — pack shot + single product
  # Strategy: 1 SerpAPI image search → grab source page → scrape all product images from it
  def find_three_images(gtin, market, official_data)
    return [nil, nil] if SERPAPI_KEY.nil? || SERPAPI_KEY.empty?
    gl = market == "UK" ? "gb" : market.downcase
    hl = @hl_codes[market] || "en"
    results = []

    # Image 1: Registry image — fastest and most reliable, always correct product
    if official_data && is_good_image_size?(official_data['image'])
      encoded = download_and_encode(official_data['image'], "https://www.ean-search.org/?q=#{gtin}")
      results << encoded if encoded
    end

    # Single SerpAPI image search — GTIN is the most reliable query
    source_page_url = nil
    direct_image_urls = []

    begin
      res = Timeout.timeout(12) {
        GoogleSearch.new(
          q: "\"#{gtin}\"",
          tbm: "isch", gl: gl, hl: hl,
          api_key: SERPAPI_KEY
        ).get_hash
      }
      images = res[:images_results] || []

      images.first(10).each do |img|
        url = img[:original]
        page = img[:link]
        next if url.nil? || url.include?("placeholder")
        next if %w[pinterest ebay tiktok facebook instagram openfoodfacts].any? { |b| url.include?(b) }

        direct_image_urls << url
        # Capture the first clean source page for deep scraping
        if source_page_url.nil? && page && !%w[pinterest ebay tiktok facebook instagram].any? { |b| page.include?(b) }
          source_page_url = page
        end
      end
    rescue => e
      log("IMG search error: #{e.message}")
    end

    # Try to scrape the source page to get all product images from same listing
    source_images = []
    if source_page_url && results.length < 2
      begin
        agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
        resp = Timeout.timeout(8) { HTTParty.get(source_page_url, headers: { "User-Agent" => agent }, timeout: 7) }

        if resp&.code == 200
          doc = Nokogiri::HTML(resp.body)
          # Find all img tags with meaningful src — product images are typically large
          doc.css('img[src]').each do |img_tag|
            src = img_tag['src'] || img_tag['data-src'] || img_tag['data-lazy-src']
            next unless src
            src = URI.join(source_page_url, src).to_s rescue src
            next if src.include?("logo") || src.include?("icon") || src.include?("banner")
            next if %w[pinterest ebay tiktok facebook instagram openfoodfacts placeholder].any? { |b| src.include?(b) }
            source_images << src unless source_images.include?(src)
          end
          log("IMG source page scraped #{source_images.length} candidates from #{source_page_url}")
        end
      rescue => e
        log("IMG source page scrape error: #{e.message}")
      end
    end

    # Combine: source page images first (same product, multiple angles), then direct search results
    candidate_urls = (source_images + direct_image_urls).uniq.reject { |u| results.any? { |r| r && r[:url] == u } }

    candidate_urls.each do |url|
      break if results.length >= 2
      next unless is_good_image_size?(url)
      encoded = download_and_encode(url, source_page_url)
      results << encoded if encoded
    end

    # Pad to 2
    results + [nil] * (2 - results.length)
  end

  def is_good_image_size?(url)
    return false if url.nil? || url.empty?
    begin
      size = Timeout.timeout(4) { FastImage.size(url, timeout: 3, http_header: { 'User-Agent' => 'Mozilla/5.0' }) }
      return false unless size
      w, h = size
      w > 200 && (w.to_f / h.to_f).between?(0.2, 3.5)
    rescue; false end
  end

  def download_and_encode(url, source)
    tempfile = Down.download(url, max_size: 2 * 1024 * 1024, open_timeout: 5, read_timeout: 5,
      headers: {
        "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36",
        "Accept" => "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        "Referer" => (source || "https://www.google.com/")
      })
    type = FastImage.type(tempfile.path)
    mime = mime_from_fastimage(type)
    return nil unless mime
    { url: url, base64: Base64.strict_encode64(File.binread(tempfile.path)), mime: mime }
  rescue => e
    log("IMG download fail #{url}: #{e.message}")
    nil
  end

  def fetch_parallel_page_data(urls)
    return { text: "", valid_urls: [] } if urls.empty?

    # Cap same domain at 2 URLs to avoid burning ZenRows on one site
    seen_domains = {}
    deduped = urls.select do |url|
      d = URI.parse(url).host&.sub(/^www\./, '') rescue nil
      next false unless d
      seen_domains[d] = (seen_domains[d] || 0) + 1
      seen_domains[d] <= 2
    end

    threads = []
    deduped.each_with_index do |url, idx|
      threads << Thread.new do
        begin
          sleep(idx * 0.2)
          agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
          resp = HTTParty.get(url, headers: { "User-Agent" => agent }, timeout: 12)

          body = resp.body.to_s

          is_blocked  = [400, 403, 429, 503].include?(resp.code)
          is_js_shell = resp.code == 200 && (
            body.length < 1000 ||
            (body.length < 15000 && body.scan(/<script/).length > 10) ||
            body.include?("window.ShopifyAnalytics")
          )

          if (is_blocked || is_js_shell) && ZENROWS_API_KEY && !ZENROWS_API_KEY.empty?
            log("ZenRows escalation: #{url} (#{resp.code})")
            resp = HTTParty.get("https://api.zenrows.com/v1/", timeout: 20, query: {
              apikey: ZENROWS_API_KEY, url: url,
              js_render: 'true', antibot: 'true', premium_proxy: 'true', wait: '2000',
              css_extractor: '{"ingredients":".pdp-description-reviews__product-details-col-2","nutrition":".nutritionTable,.pdp-nutrition-table"}'
            })
          end

          if resp&.code == 200 && resp.body.to_s.length > 500
            doc = Nokogiri::HTML(resp.body)
            json_ld = ""
            doc.css('script[type="application/ld+json"]').each { |s| json_ld += s.content.to_s.gsub(/\s+/, " ").strip[0..3000] + " " }
            doc.css('script, style, nav, footer, iframe, header, .cookie, .breadcrumb,
                     [class*="related"], [class*="recommend"], [class*="banner"],
                     [class*="promo"], [id*="header"], [id*="footer"], [id*="nav"], [id*="menu"]').remove
            product_node = doc.at_css('[class*="product-detail"],[class*="ingredient"],[class*="nutrition"],[class*="nährwert"],[class*="zutaten"],[id*="product-detail"],[itemtype*="Product"]')
            txt = (product_node || doc).text.gsub(/\s+/, " ").strip[0..10000]
            if txt.length > 150 || json_ld.length > 100
              Thread.current[:valid] = url
              Thread.current[:text]  = "=== SOURCE: #{url} ===\nCONTENT: #{txt}\nJSON-LD: #{json_ld}\n\n"
            end
            doc = nil
          else
            log("Scrape fail #{url}: #{resp&.code}")
          end
        rescue => e; log("Scrape error #{url}: #{e.message}") end
      end
    end

    threads.each { |t| t.join(25) }
    valid_urls, texts = [], []
    threads.each { |t| if t[:valid]; valid_urls << t[:valid]; texts << t[:text]; end }
    { text: texts.join("\n"), valid_urls: valid_urls }
  end

  def fetch_official_ean_data(gtin)
    return nil if EAN_SEARCH_TOKEN.nil? || EAN_SEARCH_TOKEN.empty?
    begin
      resp = HTTParty.get("https://api.ean-search.org/api?token=#{EAN_SEARCH_TOKEN}&op=barcode-lookup&format=json&ean=#{gtin}", timeout: 4)
      return JSON.parse(resp.body).first if resp.code == 200
    rescue => e; log("EAN API error: #{e.message}") end
    nil
  end

  def analyze_with_gemini(image_data, text_data, official, gtin, market, image_note = nil)
    target_lang = @country_langs[market] || "English"
    name_info   = official.is_a?(Hash) ? official['name'] : nil
    conf_note   = image_note ? "\n#{image_note}\n" : ""

    # Build taxonomy reference for categorisation
    taxonomy_sample = CATEGORY_TAXONOMY.first(30).map { |r| r.join(" > ") }.join("\n")

    prompt = <<~PROMPT
      You are a senior consumer goods data specialist. Extract maximum available data.
      PRODUCT IDENTITY: #{name_info || 'Unknown — deduce from data'}
      GTIN: #{gtin}
      #{conf_note}
      === DATA SOURCES ===
      #{text_data[0..25000]}
      IMAGE: #{image_data ? 'Provided — read ALL text visible on pack including nutrition panel, ingredients, address, certifications' : 'Not available'}

      MARKET: #{market} | OUTPUT LANGUAGE: #{target_lang}

      INSTRUCTIONS:
      1. Translate product_name, item_description, ingredients, allergens to #{target_lang}.
         BE market: output in German, French AND Dutch.
      2. Nutrition: extract numeric 100g/ml values ONLY. No marketing text. Null if not found.
      3. Dietary tags — ONLY if explicitly confirmed by text or certification:
         Vegetarian, Vegan, Organic, Halal, Kosher, Dairy Free, Nut Free, Low Sugar, High Protein, Gluten Free, Low Fat
      4. Format — ONE only: Multipack | Sharing Size | Single
      5. Occasion — select all that apply: Breakfast, Lunchbox, BBQ, Party, Christmas, Ramadan, Meal Prep, Quick Dinner, Kids Snack
      6. Extract packaging dimensions (mm), manufacturer address, place of origin, CN/HS code, organic certification ID.
      7. Packaging type: Bottle / Can / Bag / Box / Jar / Pouch / Carton / Tube / Sachet / Other
      8. Fragile: Yes if glass/ceramic, else No. Organic: Yes if certified, else No.
      9. Gross weight estimate: net_weight_g × 1.2 (round to integer).

      CATEGORISATION — assign the single best matching row from this taxonomy (L1→L6):
      #{taxonomy_sample}
      ... (#{CATEGORY_TAXONOMY.length} total rows — pick the most specific match)
      Full taxonomy available: #{CATEGORY_TAXONOMY.map { |r| r.reject(&:empty?).join(" > ") }.join(" | ")}

      OUTPUT — strict JSON, no markdown, no extra keys:
      {
        "brand": null,
        "product_name": null,
        "item_description": null,
        "cn_code": null,
        "uom": "EA",
        "packaging": null,
        "fragile": "No",
        "net_weight_g": null,
        "gross_weight_g": null,
        "organic": "No",
        "dietary_info": null,
        "net_weight_display": null,
        "ingredients": null,
        "allergens": null,
        "may_contain": null,
        "nutri_scope": null,
        "energy_kj": null,
        "fat": null,
        "saturates": null,
        "carbs": null,
        "sugars": null,
        "protein": null,
        "fiber": null,
        "salt": null,
        "manufacturer_address": null,
        "place_of_origin": null,
        "organic_id": null,
        "pkg_length": null,
        "pkg_width": null,
        "pkg_height": null,
        "format": null,
        "occasion": null,
        "cat_l1": null,
        "cat_l2": null,
        "cat_l3": null,
        "cat_l4": null,
        "cat_l5": null,
        "cat_l6": null,
        "sources_summary": null
      }
    PROMPT

    parts = [{ text: prompt }]
    if image_data&.dig(:base64) && image_data&.dig(:mime)
      parts << { inline_data: { mime_type: image_data[:mime], data: image_data[:base64] } }
    end

    # Try all models — no limit
    ["models/gemini-2.0-flash", "models/gemini-2.0-flash-lite", "models/gemini-1.5-flash"].each do |m|
      begin
        resp = HTTParty.post(
          "https://generativelanguage.googleapis.com/v1beta/#{m}:generateContent?key=#{GEMINI_API_KEY}",
          body: { contents: [{ parts: parts }] }.to_json,
          headers: @headers, timeout: 45
        )
        if resp.code == 200
          raw = resp.dig("candidates", 0, "content", "parts", 0, "text")
          next unless raw
          return JSON.parse(raw.gsub(/```json|```/, "").strip)
        end
      rescue => e; log("Gemini #{m} error: #{e.message}") end
    end
    { "error" => "AI analysis failed" }
  end

  def empty_result(gtin, market, msg, img)
    { found: false, status: msg, gtin: gtin, market: market, image_url: img, image_url2: nil, defined_sources: [] }
  end
end

get '/' do
  erb :index
end

get '/api/search' do
  content_type :json
  begin
    MasterDataHunter.new.process_product(params[:gtin], params[:market]).to_json
  rescue => e
    STDERR.puts("[CRITICAL] #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
    { found: false, status: "Server Error", gtin: params[:gtin] }.to_json
  end
end

__END__

@@ index
<!DOCTYPE html>
<html>
<head>
  <title>TGTG AI Hunter v4.5</title>
  <style>
    body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f4f6f8;padding:20px;color:#333;}
    .container{max-width:98%;margin:0 auto;background:white;padding:25px;border-radius:12px;box-shadow:0 4px 12px rgba(0,0,0,0.08);}
    h1{color:#00816A;margin-bottom:20px;}
    .controls{display:flex;gap:15px;margin-bottom:20px;background:#eefcf9;padding:20px;border-radius:8px;border:1px solid #ccece6;}
    textarea{width:100%;height:100px;padding:12px;border:1px solid #ddd;border-radius:6px;font-family:monospace;font-size:14px;}
    button{background:#00816A;color:white;border:none;padding:12px 24px;border-radius:6px;font-weight:600;cursor:pointer;transition:background 0.2s;}
    button:hover{background:#006653;}
    button:disabled{background:#ccc;cursor:not-allowed;}
    .table-wrapper{overflow-x:auto;margin-top:25px;border:1px solid #e1e4e8;border-radius:8px;}
    table{width:100%;border-collapse:collapse;font-size:12px;min-width:6000px;}
    th{text-align:left;color:white;padding:11px 9px;white-space:nowrap;font-weight:600;letter-spacing:0.3px;}
    td{padding:9px;border-bottom:1px solid #eee;vertical-align:top;max-width:260px;line-height:1.4;}
    tr:nth-child(even){background:#f8f9fa;}
    tr:hover{background:#f1f3f5;}
    .status-badge{padding:3px 7px;border-radius:4px;font-weight:600;font-size:10px;text-transform:uppercase;white-space:nowrap;}
    .st-found{background:#d4edda;color:#155724;}
    .st-deep{background:#cce5ff;color:#004085;}
    .st-reg{background:#fff3cd;color:#856404;}
    .st-miss{background:#f8d7da;color:#721c24;}
    .imgs{display:flex;gap:4px;flex-wrap:wrap;}
    .img-thumb{width:46px;height:46px;object-fit:contain;border:1px solid #ddd;border-radius:4px;background:white;padding:2px;}
    .source-list{display:flex;flex-direction:column;gap:3px;}
    .src-btn{display:inline-flex;align-items:center;gap:4px;padding:3px 7px;border-radius:4px;font-size:10px;text-decoration:none;border:1px solid #ced4da;background:#fff;color:#495057;transition:all 0.2s;width:fit-content;}
    .src-btn:hover{border-color:#00816A;color:#00816A;background:#f0fdf9;}
    .src-registry{border-left:3px solid #00816A;}
    .src-web{border-left:3px solid #007bff;}
    .src-deep{border-left:3px solid #fd7e14;}
    .src-img{border-left:3px solid #6f42c1;}
    .ai-note{font-size:10px;color:#888;margin-bottom:4px;font-style:italic;}
    .tag{display:inline-block;padding:2px 5px;border-radius:3px;font-size:10px;font-weight:600;margin:1px;}
    .tag-diet{background:#d4edda;color:#155724;}
    .tag-format{background:#cce5ff;color:#004085;}
    .tag-occasion{background:#fff3cd;color:#856404;}
    .tag-cat{background:#e8d5f5;color:#4a1b7a;}
    .tag-yn-yes{background:#d4edda;color:#155724;}
    .tag-yn-no{background:#f8f9fa;color:#6c757d;}
    th.g1{background:#00816A;}
    th.g2{background:#005a4a;}
    th.g3{background:#006657;}
    th.g4{background:#004d3b;}
    th.g5{background:#2d6a4f;}
  </style>
</head>
<body>
<div class="container">
  <div style="display:flex;justify-content:space-between;align-items:center;">
    <h1>✨ TGTG AI Hunter <span style="font-size:0.5em;color:#666;font-weight:normal;">v4.5</span></h1>
    <span id="prog" style="font-weight:bold;color:#00816A;"></span>
  </div>
  <div class="controls">
    <div style="flex:1;">
      <label style="font-weight:bold;display:block;margin-bottom:5px;">Paste EANs (one per line):</label>
      <textarea id="inputList" placeholder="4018077669132&#10;9311493002534&#10;..."></textarea>
    </div>
    <div style="width:200px;">
      <label style="font-weight:bold;display:block;margin-bottom:5px;">Market:</label>
      <select id="mkt" style="width:100%;padding:10px;border-radius:6px;border:1px solid #ddd;">
        <option value="BE">Belgium (BE)</option><option value="DK">Denmark (DK)</option>
        <option value="DE">Germany (DE)</option><option value="AT">Austria (AT)</option>
        <option value="NL">Netherlands (NL)</option><option value="FR">France (FR)</option>
        <option value="IT">Italy (IT)</option><option value="ES">Spain (ES)</option>
        <option value="UK">United Kingdom (UK)</option><option value="PL">Poland (PL)</option>
        <option value="SE">Sweden (SE)</option><option value="NO">Norway (NO)</option>
        <option value="FI">Finland (FI)</option>
      </select>
      <button id="startBtn" onclick="startBatch()" style="width:100%;margin-top:10px;">🚀 Analyze</button>
      <button id="dlBtn" onclick="downloadCSV()" style="width:100%;margin-top:5px;background:#343a40;display:none;">⬇️ CSV</button>
    </div>
  </div>
  <div class="table-wrapper">
    <table id="tbl">
      <thead><tr>
        <th class="g1">Status</th><th class="g1">Images</th><th class="g1">GTIN/EAN</th>
        <th class="g1">Brand</th><th class="g1">Product Name</th><th class="g1">Item Description</th>
        <th class="g1">Origin</th><th class="g1">Sources</th>
        <th class="g2">CN Code</th><th class="g2">UoM</th><th class="g2">Packaging</th>
        <th class="g2">Fragile</th><th class="g2">Net Wt (g)</th><th class="g2">Gross Wt (g)</th>
        <th class="g2">Net Wt Display</th><th class="g2">Organic</th>
        <th class="g1">Dietary Info</th><th class="g1">Organic ID</th>
        <th class="g1">Ingredients</th><th class="g1">Allergens</th><th class="g1">May Contain</th>
        <th class="g1">Manufacturer Address</th><th class="g1">Place of Origin</th>
        <th class="g3">Nutri Scope</th><th class="g3">Energy (kJ)</th><th class="g3">Fat (g)</th>
        <th class="g3">Saturates (g)</th><th class="g3">Carbs (g)</th><th class="g3">Sugars (g)</th>
        <th class="g3">Fiber (g)</th><th class="g3">Protein (g)</th><th class="g3">Salt (g)</th>
        <th class="g4">Pkg L (mm)</th><th class="g4">Pkg W (mm)</th><th class="g4">Pkg H (mm)</th>
        <th class="g1">Format</th><th class="g1">Occasion</th>
        <th class="g5">Cat L1</th><th class="g5">Cat L2</th><th class="g5">Cat L3</th>
        <th class="g5">Cat L4</th><th class="g5">Cat L5</th><th class="g5">Cat L6</th>
      </tr></thead>
      <tbody></tbody>
    </table>
  </div>
</div>
<script>
let resultsData=[];
const COLS=44;

async function startBatch(){
  const lines=document.getElementById('inputList').value.split('\n').map(l=>l.trim()).filter(Boolean);
  if(!lines.length){alert("Paste some EANs first.");return;}
  const mkt=document.getElementById('mkt').value;
  document.getElementById('startBtn').disabled=true;
  const tbody=document.querySelector('#tbl tbody');
  tbody.innerHTML=''; resultsData=[];
  const rows=lines.map(g=>{
    const tr=document.createElement('tr');
    tr.innerHTML=`<td><span class="status-badge" style="background:#eee;color:#666;">...</span></td>${'<td></td>'.repeat(COLS-1)}`;
    tbody.appendChild(tr); resultsData.push(null); return tr;
  });
  let done=0;
  const upd=()=>document.getElementById('prog').innerText=`Processing: ${done}/${lines.length}`;
  upd();
  let idx=0;
  async function worker(){
    while(idx<lines.length){
      const i=idx++, g=lines[i], tr=rows[i];
      try{
        const d=await fetch(`/api/search?gtin=${g}&market=${mkt}`).then(r=>r.json());
        resultsData[i]=d; renderRow(tr,g,d);
      }catch(e){
        tr.innerHTML=`<td colspan="${COLS}" style="color:red;text-align:center;">Error: ${g}</td>`;
      }
      done++; upd();
    }
  }
  await Promise.all([worker(),worker(),worker()]);
  document.getElementById('startBtn').disabled=false;
  document.getElementById('dlBtn').style.display='block';
  document.getElementById('prog').innerText='✅ Complete';
}

function tags(val,cls){
  if(!val||val==='null')return'-';
  return String(val).split(',').map(t=>t.trim()).filter(Boolean).map(t=>`<span class="tag ${cls}">${t}</span>`).join('');
}
function yn(val){
  if(!val||val==='null')return'-';
  const v=String(val).trim();
  return `<span class="tag ${v.toLowerCase()==='yes'?'tag-yn-yes':'tag-yn-no'}">${v}</span>`;
}
function f(val){
  if(val===null||val===undefined)return'-';
  if(Array.isArray(val))val=val.join(', ');
  if(typeof val==='object')val=JSON.stringify(val);
  const s=String(val).trim();
  return(!s||s==='null')?'-':s.replace(/\n/g,'<br>');
}

function renderRow(tr,gtin,d){
  let sc='st-found';
  if(d.status?.includes('Registry'))sc='st-reg';
  if(d.status?.includes('Deep'))sc='st-deep';
  if(d.status?.includes('Error')||d.status?.includes('Missing')||d.status?.includes('Blind'))sc='st-miss';

  const imgs=[d.image_url,d.image_url2].filter(Boolean);
  const imgHTML=imgs.length?`<div class="imgs">${imgs.map(u=>`<a href="${u}" target="_blank"><img src="${u}" class="img-thumb" onerror="this.style.display='none'"></a>`).join('')}</div>`:'-';

  let src=`<div class="source-list">`;
  if(d.sources_summary)src+=`<span class="ai-note">${d.sources_summary}</span>`;
  (d.defined_sources||[]).forEach(s=>{
    let icon='🔗',cls='src-web';
    if(s.type==='registry'){icon='🏛️';cls='src-registry';}
    if(s.type==='image'){icon='📸';cls='src-img';}
    if(s.type==='rescue'){icon='🔍';cls='src-deep';}
    src+=`<a href="${s.url}" target="_blank" class="src-btn ${cls}">${icon} ${s.title}</a>`;
  });
  if(!(d.defined_sources||[]).length)src+=`<span style="font-size:11px;color:#999">No links</span>`;
  src+=`</div>`;

  tr.innerHTML=`
    <td><span class="status-badge ${sc}">${d.status||'-'}</span></td>
    <td>${imgHTML}</td>
    <td style="font-family:monospace;font-size:11px;">${gtin}</td>
    <td>${f(d.brand)}</td>
    <td style="font-weight:600;">${f(d.product_name)}</td>
    <td style="font-size:11px;">${f(d.item_description)}</td>
    <td style="text-align:center;">${f(d.issuing_country)}</td>
    <td>${src}</td>
    <td style="font-family:monospace;">${f(d.cn_code)}</td>
    <td>${f(d.uom)}</td>
    <td>${f(d.packaging)}</td>
    <td>${yn(d.fragile)}</td>
    <td>${f(d.net_weight_g)}</td>
    <td>${f(d.gross_weight_g)}</td>
    <td>${f(d.net_weight_display)}</td>
    <td>${yn(d.organic)}</td>
    <td>${tags(d.dietary_info,'tag-diet')}</td>
    <td style="font-family:monospace;font-size:11px;">${f(d.organic_id)}</td>
    <td style="font-size:11px;">${f(d.ingredients)}</td>
    <td style="font-size:11px;">${f(d.allergens)}</td>
    <td style="font-size:11px;">${f(d.may_contain)}</td>
    <td style="font-size:11px;">${f(d.manufacturer_address)}</td>
    <td>${f(d.place_of_origin)}</td>
    <td>${f(d.nutri_scope)}</td>
    <td>${f(d.energy_kj)}</td>
    <td>${f(d.fat)}</td>
    <td>${f(d.saturates)}</td>
    <td>${f(d.carbs)}</td>
    <td>${f(d.sugars)}</td>
    <td>${f(d.fiber)}</td>
    <td>${f(d.protein)}</td>
    <td>${f(d.salt)}</td>
    <td>${f(d.pkg_length)}</td>
    <td>${f(d.pkg_width)}</td>
    <td>${f(d.pkg_height)}</td>
    <td>${tags(d.format,'tag-format')}</td>
    <td>${tags(d.occasion,'tag-occasion')}</td>
    <td>${tags(d.cat_l1,'tag-cat')}</td>
    <td>${tags(d.cat_l2,'tag-cat')}</td>
    <td>${tags(d.cat_l3,'tag-cat')}</td>
    <td>${tags(d.cat_l4,'tag-cat')}</td>
    <td>${tags(d.cat_l5,'tag-cat')}</td>
    <td>${tags(d.cat_l6,'tag-cat')}</td>`;
}

function downloadCSV(){
  const hdrs=["Status","GTIN/EAN","Brand","Product Name","Item Description","Origin","Sources",
    "CN Code","UoM","Packaging","Fragile","Net Wt(g)","Gross Wt(g)","Net Wt Display","Organic",
    "Dietary Info","Organic ID","Ingredients","Allergens","May Contain","Manufacturer Address","Place of Origin",
    "Nutri Scope","Energy(kJ)","Fat(g)","Saturates(g)","Carbs(g)","Sugars(g)","Fiber(g)","Protein(g)","Salt(g)",
    "Pkg L(mm)","Pkg W(mm)","Pkg H(mm)","Format","Occasion",
    "Cat L1","Cat L2","Cat L3","Cat L4","Cat L5","Cat L6"];
  const c=v=>'"'+String(v==null?'':v).replace(/"/g,'""').replace(/\n/g,' | ')+'"';
  let csv=hdrs.join(',')+'\n';
  resultsData.filter(Boolean).forEach(r=>{
    const src=(r.defined_sources||[]).map(s=>`[${s.type.toUpperCase()}: ${s.url}]`).join(' | ');
    csv+=[c(r.status),c(r.gtin),c(r.brand),c(r.product_name),c(r.item_description),
      c(r.issuing_country),c(src),c(r.cn_code),c(r.uom),c(r.packaging),c(r.fragile),
      c(r.net_weight_g),c(r.gross_weight_g),c(r.net_weight_display),c(r.organic),
      c(r.dietary_info),c(r.organic_id),c(r.ingredients),c(r.allergens),c(r.may_contain),
      c(r.manufacturer_address),c(r.place_of_origin),c(r.nutri_scope),c(r.energy_kj),
      c(r.fat),c(r.saturates),c(r.carbs),c(r.sugars),c(r.fiber),c(r.protein),c(r.salt),
      c(r.pkg_length),c(r.pkg_width),c(r.pkg_height),c(r.format),c(r.occasion),
      c(r.cat_l1),c(r.cat_l2),c(r.cat_l3),c(r.cat_l4),c(r.cat_l5),c(r.cat_l6)
    ].join(',')+'\n';
  });
  const a=document.createElement('a');
  a.href='data:text/csv;charset=utf-8,'+encodeURI(csv);
  a.download='tgtg_hunter_results.csv';
  a.click();
}
</script>
</body>
</html>
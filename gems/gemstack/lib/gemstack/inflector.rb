# frozen_string_literal: true

module GemStack
  # English inflections used by conventions (routes, generators, constants).
  #
  #   Inflector.pluralize("category")      # => "categories"
  #   Inflector.camelize("inventory_item") # => "InventoryItem"
  #   Inflector.underscore("InventoryItem")# => "inventory_item"
  #
  # Extend with Inflector.irregular("person", "people") or
  # Inflector.uncountable("equipment") — typically in config/app.rb.
  module Inflector
    PLURALS = [
      [/(quiz)\z/i, '\1zes'],
      [/\A(ox)\z/i, '\1en'],
      [/(matr|vert|ind)(?:ix|ex)\z/i, '\1ices'],
      [/(x|ch|ss|sh|zz)\z/i, '\1es'],
      [/([^aeiouy]|qu)y\z/i, '\1ies'],
      [/(?:([^f])fe|([lr])f)\z/i, '\1\2ves'],
      [/sis\z/i, "ses"],
      [/([ti])um\z/i, '\1a'],
      [/(buffal|tomat|potat|her|ech)o\z/i, '\1oes'],
      [/(bu|mis|ga|alia|statu|stat|vir|octop|cact)us\z/i, '\1uses'],
      [/s\z/i, "s"],
      [/\z/, "s"]
    ].freeze

    SINGULARS = [
      [/(quiz)zes\z/i, '\1'],
      [/(matr)ices\z/i, '\1ix'],
      [/(vert|ind)ices\z/i, '\1ex'],
      [/\A(ox)en/i, '\1'],
      [/(alias|status|bus|campus|virus|octopus|cactus)(es)?\z/i, '\1'],
      [/(x|ch|ss|sh|zz)es\z/i, '\1'],
      [/(m)ovies\z/i, '\1ovie'],
      [/([^aeiouy]|qu)ies\z/i, '\1y'],
      [/([lr])ves\z/i, '\1f'],
      [/([^f])ves\z/i, '\1fe'],
      [/(analy|ba|diagno|parenthe|progno|synop|the)ses\z/i, '\1sis'],
      [/(buffal|tomat|potat|her|ech)oes\z/i, '\1o'],
      [/([ti])a\z/i, '\1um'],
      [/ss\z/i, "ss"],
      [/s\z/i, ""]
    ].freeze

    DEFAULT_IRREGULARS = {
      "person" => "people", "man" => "men", "woman" => "women", "child" => "children",
      "mouse" => "mice", "goose" => "geese", "tooth" => "teeth", "foot" => "feet"
    }.freeze

    DEFAULT_UNCOUNTABLES = %w[equipment information rice money species series fish sheep deer news data].freeze

    @irregulars = DEFAULT_IRREGULARS.dup
    @uncountables = DEFAULT_UNCOUNTABLES.dup

    class << self
      def irregular(singular, plural)
        @irregulars[singular.downcase] = plural.downcase
      end

      def uncountable(*words)
        @uncountables.concat(words.flatten.map(&:downcase))
      end

      def pluralize(word)
        inflect(word.to_s, @irregulars, PLURALS)
      end

      def singularize(word)
        inflect(word.to_s, @irregulars.invert, SINGULARS)
      end

      # "inventory_item" / "inventory-item" => "InventoryItem";
      # "admin/products" => "Admin::Products"
      def camelize(term)
        term.to_s.split("/").map do |part|
          part.split(/[_-]/).map { |w| w[0] ? w[0].upcase + w[1..] : w }.join
        end.join("::")
      end

      # "InventoryItem" => "inventory_item"; "Admin::Products" => "admin/products"
      def underscore(term)
        term.to_s.gsub("::", "/")
            .gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .tr("-", "_")
            .downcase
      end

      def dasherize(term) = underscore(term).tr("_", "-")

      # "inventory_item" => "Inventory item"
      def humanize(term)
        words = underscore(term).delete_suffix("_id").tr("_", " ")
        words[0] ? words[0].upcase + words[1..] : words
      end

      # "inventory_items" => "InventoryItem"
      def classify(term) = camelize(singularize(term.to_s))

      # "InventoryItem" => "inventory_items"
      def tableize(term) = pluralize(underscore(term))

      private

      # irregulars maps source form => target form (e.g. "person" => "people").
      def inflect(word, irregulars, rules)
        return word if word.empty?

        prefix, last = split_last_word(word)
        lower = last.downcase
        return word if @uncountables.include?(lower) || irregulars.value?(lower)
        return prefix + match_case(last, irregulars[lower]) if irregulars.key?(lower)

        rules.each do |pattern, replacement|
          return prefix + last.sub(pattern, replacement) if last.match?(pattern)
        end
        word
      end

      # Only the final word is inflected: "line_item" => ["line_", "item"],
      # "LineItem" => ["Line", "Item"].
      def split_last_word(word)
        match = word.match(/\A(.*[_\-\s])([^_\-\s]+)\z/m) || word.match(/\A(.*[a-z\d])([A-Z][^A-Z]*)\z/)
        match ? [match[1], match[2]] : ["", word]
      end

      def match_case(original, replacement)
        original[0] == original[0].upcase ? replacement[0].upcase + replacement[1..] : replacement
      end
    end
  end
end

module Edi
  module Formatter

    def to_edi(options={})
      options.reverse_merge!(field_separator: '*',
                             segment_separator: :new_line,
                             seg_sep_suppress: '<<seg. sep.>>',
                             inline_field_separator: ':')
      output = record_to_edi(data_type = (model = self.orm_model).data_type, options, model.schema, self)
      seg_sep = options[:segment_separator] == :new_line ? "\r\n" : options[:segment_separator].to_s
      output.join(seg_sep)
    end

    def to_hash(options={})
      [:ignore, :only, :embedding].each do |option|
        value = (options[option] || [])
        value = [value] unless value.is_a?(Enumerable)
        value = value.select { |p| p.is_a?(Symbol) || p.is_a?(String) }.collect(&:to_sym)
        options[option] = value
      end
      options.delete(:only) if options[:only].empty?
      hash = record_to_hash(self, options)
      hash = {self.orm_model.data_type.name.downcase => hash} if options[:include_root]
      hash
    end

    def to_json(options={})
      hash = to_hash(options)
      options[:pretty] ? JSON.pretty_generate(hash) : hash.to_json
    end

    def to_xml(options={})
      (xml_doc = Nokogiri::XML::Document.new) << record_to_xml_element(data_type = self.orm_model.data_type, JSON.parse(data_type.model_schema), self, xml_doc, nil, options)
      xml_doc.to_xml
    end

    private

    def record_to_xml_element(data_type, schema, record, xml_doc, enclosed_property_name, options)
      return unless record
      return Nokogiri::XML({enclosed_property_name => record}.to_xml).root.first_element_child if Cenit::Utility.json_object?(record)
      required = schema['required'] || []
      attr = {}
      elements = []
      content = nil
      content_property = nil
      schema['properties'].each do |property_name, property_schema|
        property_schema = data_type.merge_schema(property_schema)
        name = property_schema['edi']['segment'] if property_schema['edi']
        name ||= property_name
        case property_schema['type']
        when 'array'
          property_value = record.send(property_name)
          xml_opts = property_schema['xml'] || {}
          if xml_opts['attribute']
            property_value = property_value && property_value.collect(&:to_s).join(' ')
            attr[name] = property_value if !property_value.blank? || options[:with_blanks] || required.include?(property_name)
          elsif xml_opts['simple_type']
            elements << (e = xml_doc.create_element(name))
            e << property_value && property_value.collect(&:to_s).join(' ')
          else
            property_schema = data_type.merge_schema(property_schema['items'])
            json_objects = []
            property_value && property_value.each do |sub_record|
              if Cenit::Utility.json_object?(sub_record)
                json_objects << sub_record
              else
                elements << record_to_xml_element(data_type, property_schema, sub_record, xml_doc, property_name, options)
              end
            end
            unless json_objects.empty?
              elements << Nokogiri::XML({property_name => json_objects}.to_xml).root.first_element_child
            end
          end
        when 'object'
          elements << record_to_xml_element(data_type, property_schema, record.send(property_name), xml_doc, property_name, options)
        else
          value = property_schema['default'] unless value = record.send(property_name)
          if value
            xml_opts = property_schema['xml'] || {}
            if xml_opts['attribute']
              attr[name] = value if !value.blank? || options[:with_blanks] || required.include?(property_name)
            elsif xml_opts['content']
              if content.nil?
                content = value
                content_property = property_name
              else
                raise Exception.new("More than one content property found: '#{content_property}' and '#{property_name}'")
              end
            else
              elements << Nokogiri::XML({name => value}.to_xml).root.first_element_child
            end
          end
        end
      end
      name = schema['edi']['segment'] if schema['edi']
      name ||= enclosed_property_name || record.orm_model.data_type.name
      element = xml_doc.create_element(name, attr)
      if elements.empty?
        content =
          case content
          when NilClass
            []
          when Hash
            Nokogiri::XML(content.to_xml).root.element_children
          else
            [content]
          end
        content.each { |e| element << e }
      else
        raise Exception.new("Incompatible content property ('#{content_property}') in presence of complex content") if content_property
        elements.each { |e| element << e if e }
      end
      element
    end

    def record_to_hash(record, options = {}, referenced = false, enclosed_model = nil)
      return record if Cenit::Utility.json_object?(record)
      data_type = record.orm_model.data_type
      schema = record.orm_model.schema
      json = (referenced = referenced && schema['referenced_by']) ? {'_reference' => true} : {}
      schema['properties'].each do |property_name, property_schema|
        property_schema = data_type.merge_schema(property_schema)
        property_model = record.orm_model.property_model(property_name)
        name = property_schema['edi']['segment'] if property_schema['edi']
        name ||= property_name
        can_be_referenced = !(options[:embedding_all] || options[:embedding].include?(name.to_sym))
        next if property_schema['virtual'] ||
          ((property_schema['edi'] || {})['discard'] && !(included_anyway = options[:including_discards])) ||
        (can_be_referenced && referenced && !referenced.include?(property_name)) ||
          options[:ignore].include?(name.to_sym) ||
          (options[:only] && !options[:only].include?(name.to_sym) && !included_anyway)

        case property_schema['type']
        when 'array'
          referenced_items = can_be_referenced && property_schema['referenced'] && !property_schema['export_embedded']
          if value = record.send(property_name)
            value = value.collect { |sub_record| record_to_hash(sub_record, options, referenced_items, property_model) }
            json[name] = value unless value.empty?
          end
        when 'object'
          json[name] = value if value =
            record_to_hash(record.send(property_name), options, can_be_referenced && property_schema['referenced'] && !property_schema['export_embedded'], property_model)
        else
          if (value = record.send(property_name) || property_schema['default']).is_a?(BSON::ObjectId)
            value = value.to_s
          end
          json[name] = value unless value.nil?
        end
      end
      if !json['_reference'] && enclosed_model && record.orm_model != enclosed_model && !options[:ignore].include?(:_type) && (!options[:only] || options[:only].include?(:_type))
        json['_type'] = data_type.name
      end
      json
    end

    def record_to_edi(data_type, options, schema, record, enclosed_property_name=nil)
      output = []
      return output unless record
      field_sep = options[:field_separator]
      segment =
        if (edi_options = schema['edi'] || {})['virtual']
          ''
        else
          edi_options['segment'] ||
            if (record_data_type = record.orm_model.data_type) != data_type
              record_data_type.name
            else
              enclosed_property_name || data_type.name
            end
        end
      schema['properties'].each do |property_name, property_schema|
        property_schema = data_type.merge_schema(property_schema)
        next if property_schema['edi'] && property_schema['edi']['discard']
        if (property_model = record.orm_model.property_model(property_name)) && property_model.modelable?
          if property_schema['type'] == 'array'
            property_schema = data_type.merge_schema(property_schema['items'])
            record.send(property_name).each do |sub_record|
              output.concat(record_to_edi(data_type, options, property_schema, sub_record, property_name))
            end
          else
            if sub_record = record.send(property_name)
              if property_schema['edi'] && property_schema['edi']['inline']
                value = []
                property_model.properties_schemas.each do |property_name, property_schema|
                  value << edi_value(sub_record, property_name, property_schema, sub_record.orm_model.property_model(property_name), options)
                end
                segment +=
                  if field_sep == :by_fixed_length
                    value.join
                  else
                    while value.last.blank?
                      value.pop
                    end
                    field_sep + value.join(options[:inline_field_separator])
                  end
              else
                output.concat(record_to_edi(data_type, options, property_schema, sub_record, property_name))
              end
            end
          end
        else
          value = edi_value(record, property_name, property_schema, property_model, options)
          segment +=
            if field_sep == :by_fixed_length
              value
            else
              field_sep + value
            end
        end
      end
      while segment.end_with?(field_sep)
        segment = segment.chomp(field_sep)
      end
      output.unshift(segment) unless edi_options['virtual']
      output
    end

    def edi_value(record, property_name, property_schema, property_model, options)
      unless value = record[property_name]
        value = property_schema['default'] || ''
      end
      value = property_model.to_string(value) if property_model
      value =
        if (segment_sep = options[:segment_separator]) == :new_line
          value.to_s.gsub(/(\n|\r|\r\n)+/, options[:seg_sep_suppress])
        else
          value.to_s.gsub(segment_sep, options[:seg_sep_suppress])
        end
      if options[:field_separator] == :by_fixed_length
        if (max_len = property_schema['maxLength']) && (auto_fill = property_schema['auto_fill'])
          case auto_fill[0]
          when 'R'
            value += auto_fill[1] until value.length == max_len
          when 'L'
            value = auto_fill[1] + value until value.length == max_len
          end
        end
      end
      value
    end

  end
end

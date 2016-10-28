module Setup
  class Resource
    include CenitScoped
    include NamespaceNamed
    
    belongs_to :section, class_name: Setup::Section.to_s, inverse_of: :nil
    has_many :operations, class_name: Setup::Operation.to_s, inverse_of: :nil
    
    field :path, type: String
    field :description, type: String
    
    validates_presence_of :path
  end
end

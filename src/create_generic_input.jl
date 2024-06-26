#=
    create_generic_input.jl

Create ArBuMo.jl structure for Spine Datastores,
mostly for debugging purposes.
=#

"""
    GenericInput

Create and store the ArBuMo.jl structure for Spine Data Stores.

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Contains the following fields:
 - `building_archetype::ObjectClass`: Stores [`ArchetypeBuilding`](@ref) information and definitions.
 - `building_scope::ObjectClass`: Stores [`ScopeData`](@ref) information and definitions.
 - `building_archetype__building_scope::RelationshipClass`: Links [`ArchetypeBuilding`](@ref) to its corresponding [`ScopeData`](@ref).
"""
struct GenericInput <: ModelInput
    building_archetype::ObjectClass
    building_scope::ObjectClass
    building_archetype__building_scope::RelationshipClass
    function GenericInput(; mod=@__MODULE__)
        building_archetype = deepcopy(mod.building_archetype)
        building_scope = deepcopy(mod.building_scope)
        building_archetype__building_scope =
            deepcopy(mod.building_archetype__building_scope)
        new(
            building_archetype,
            building_scope,
            building_archetype__building_scope,
        )
    end
end


"""
    GenericInput(
        results::Dict{Object,ArchetypeBuildingResults};
        mod::Module=@__MODULE__
    )

Create [`GenericInput`](@ref) based on a given archetype building results.

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Essentially, performs the following steps:
1. Initialize an empty [`GenericInput`](@ref).
2. Loop over the given `archetypes`, and [`add_archetype_to_input!`](@ref) one by one.
"""
function GenericInput(
    results::Dict{Object,ArchetypeBuildingResults};
    mod::Module=@__MODULE__
)
    generic = GenericInput(; mod=mod)
    for result in values(results)
        add_archetype_to_input!(generic, result)
    end
    return generic
end


"""
    add_archetype_to_input!(
        generic::GenericInput,
        result::ArchetypeBuildingResults
    )

Add [`ArchetypeBuildingResults`](@ref) to [`GenericInput`](@ref).

Essentially goes over the fields of the contained [`ArchetypeBuilding`](@ref)
and parses them into `Map` for Spine export.
"""
function add_archetype_to_input!(generic::GenericInput, result::ArchetypeBuildingResults)
    # Fetch the contained `ArchetypeBuilding`
    archetype = result.archetype

    # Add scope data.
    add_object_parameter_values!(
        generic.building_scope,
        Dict(archetype.scope => Dict(:scope_data => parameter_value(archetype.scope_data))),
    )
    generic.building_scope.parameter_defaults[:scope_data] = parameter_value(nothing)

    # Define archetype fields of interest
    fields = [
        :envelope_data,
        :building_nodes,
        :building_processes,
        :loads_data,
        :weather_data,
        :abstract_nodes
    ]

    # Loop over archetype fields of interest and add data
    add_object_parameter_values!(
        generic.building_archetype,
        Dict(
            archetype.archetype =>
                Dict(f => parameter_value(getfield(archetype, f)) for f in fields),
        ),
    )
    merge!(
        generic.building_archetype.parameter_defaults,
        Dict(f => parameter_value(nothing) for f in fields),
    )
    return nothing
end


## Extensions to `SpineInterface.parameter_value`.

function SpineInterface.parameter_value(d::Union{Dict,NamedTuple})
    return parameter_value(Map(collect(string.(keys(d))), collect(values(d))))
end
function SpineInterface.parameter_value(bdt::BuildingDataType)
    ks = collect(fieldnames(typeof(bdt)))
    return parameter_value(Map(ks, [getfield(bdt, k) for k in ks]))
end
SpineInterface.parameter_value(obj::Object) = parameter_value(obj.name)
SpineInterface.parameter_value(v::Vector{Object}) =
    parameter_value(string.(getfield.(v, :name)))

#=
    types.jl

This file contains data structures and constructors for the archetype buildings.
=#

"""
    BuildingDataType

Abstract type for ArBuMo data structures.
"""
abstract type BuildingDataType end


"""
    StructureData <: BuildingDataType

Store the important aggregated parameters for a structure type.

This type is used by the [`process_structure_scope`](@ref) function to store the
gross-floor-area-averaged structural properties within the desired `scope`.
Contains the following fields:
- `structure_type::Object`: Type of the structure, e.g. `base_floor` or `roof`.
- `design_U_value_W_m2K::Float64`: Design U-value of the structure in [W/m2K].
- `effective_thermal_mass_J_m2K::Float64`: Effective thermal mass of the structure in [J/m2K].
- `external_U_value_to_ambient_air_W_m2K::Float64`: U-value from the structure to ambient air in [W/m2K].
- `external_U_value_to_ground_W_m2K::Float64`: U-value from the structure to ground in [W/m2K].
- `internal_U_value_to_structure_W_m2K::Float64`: U-value from the structure to the interior air in [W/m2K].
- `linear_thermal_bridges_W_mK::Float64`: Linear thermal bridges in the structure in [W/mK].
- `total_U_value_W_m2K::Float64`: Total U-value through the structure.
"""
struct StructureData <: BuildingDataType
    structure_type::Object
    design_U_value_W_m2K::Float64
    effective_thermal_mass_J_m2K::Float64
    external_U_value_to_ambient_air_W_m2K::Float64
    external_U_value_to_ground_W_m2K::Float64
    internal_U_value_to_structure_W_m2K::Float64
    linear_thermal_bridges_W_mK::Float64
    total_U_value_W_m2K::Float64
    """
        StructureData(structure_type::Object, args...)

    Construct a new `StructureData` and check that all fields are positive.
    """
    function StructureData(structure_type::Object, args...)
        for (i, arg) in enumerate(args)
            arg >= 0 ||
                @warn "`$(fieldnames(StructureData)[i+1])` for `$(structure_type)` shouldn't be negative!"
        end
        new(structure_type, args...)
    end
end


"""
    ScopeData(scope::Object; mod::Module = @__MODULE__) <: BuildingDataType

Aggregate and store data defined by a `building_scope` object.

Essentially, stores information about the aggregated properties of the desired
portion of the building stock, as defined by the `building_scope` object in the
archetype building definition database.

NOTE! The `mod` keyword changes from which Module data is accessed from
by the constructor, `@__MODULE__` by default.

This struct contains the following fields:
- `building_scope::Object`: The `building_scope` used to define this `ScopeData`.
- `number_of_buildings::Float64`: Number of buildings included in this `scope`.
- `average_gross_floor_area_m2_per_building::Float64`: Average GFA per building in [m2] of the buildings included in this `scope`.
- `HRU_efficiency::Float64`: Average ventilation heat-recovery unit efficiency of the buildings included in this `scope`.
- `infiltration_rate_1_h::Float64`: Average infiltration rate in [1/h] of the buildings included in this `scope`.
- `total_normal_solar_energy_transmittance::Float64`: Average total normal solar energy transmittance of the windows included in this `scope`.
- `ventilation_rate_1_h::Float64`: Average ventilation rate in [1/h] of the buildings included in this `scope`.
- `window_U_value_W_m2K::Float64`: Average window U-value in [W/m2K] of the buildings included in this `scope`.
- `structure_data::Dict{Object,StructureData}`: [`StructureData`](@ref) dictionary for the average structural parameters of the buildings included in this `scope`.
- `location_id_gfa_weights::Dict{Object,Float64}`: Gross-floor area weights for the `location_id`s included in this `scope`, used for automatic weather data processing.
- `shapefile_path::String`: Path to a shapefile describing the geography of this `scope`, used for the automatic weather data aggregation.
- `raster_weight_path::Union{String,Nothing}`: Optional path to a raster weight map for tweaking the automatic weather data aggregation.

The constructor essentially performs the following steps:
1. Process building stock statistics using the [`process_building_stock_scope`](@ref) function.
2. Process ventilation and fenestration statistics using the [`process_ventilation_and_fenestration_scope`](@ref) function.
3. Process structure statistics using the [`process_structure_scope`](@ref) function.
4. Check that the values make sense.
5. Create the `ScopeData`.
"""
struct ScopeData <: BuildingDataType
    building_scope::Object
    number_of_buildings::Float64
    average_gross_floor_area_m2_per_building::Float64
    HRU_efficiency::Float64
    infiltration_rate_1_h::Float64
    total_normal_solar_energy_transmittance::Float64
    ventilation_rate_1_h::Float64
    window_U_value_W_m2K::Float64
    structure_data::Dict{Object,StructureData}
    location_id_gfa_weights::Dict{Object,Float64}
    shapefile_path::String
    raster_weight_path::Union{String,Nothing}
    """
        ScopeData(scope::Object; mod::Module = @__MODULE__)

    Construct a new `ScopeData` based on the given `scope`.
    """
    function ScopeData(scope::Object; mod::Module=@__MODULE__)
        (
            avg_gfa_m2_per_building,
            num_buildings,
            gfa_weights,
            aggregated_gfa_weights,
            location_id_gfa_weights,
        ) = process_building_stock_scope(scope; mod=mod)
        hru_eff, inf_rate, sol_transm, ven_rate, win_U =
            process_ventilation_and_fenestration_scope(aggregated_gfa_weights; mod=mod)
        structure_data = process_structure_scope(aggregated_gfa_weights; mod=mod)
        shape_path = string(
            mod.shapefile_path(
                building_stock=first(
                    mod.building_scope__building_stock(building_scope=scope),
                ),
            ),
        )
        raster_path = mod.raster_weight_path(
            building_stock=first(
                mod.building_scope__building_stock(building_scope=scope),
            ),
        )
        !isnothing(raster_path) ? raster_path = string(raster_path) : nothing
        for (field, val) in [
            :average_gross_floor_area_m2_per_building => avg_gfa_m2_per_building,
            :number_of_buildings => num_buildings,
            :infiltration_rate_1_h => inf_rate,
            :ventilation_rate_1_h => ven_rate,
            :window_U_value_W_m2K => win_U,
        ]
            val >= 0 || @warn "`$(field)` for `$(scope)` shouldn't be negative!"
        end
        for (field, val) in [
            :HRU_efficiency => hru_eff,
            :total_normal_solar_energy_transmittance => sol_transm,
        ]
            0 <= val <= 1 || @warn "`$(field)` for `$(scope)` should be between [0,1]!"
        end
        for (field, val) in [
            :gross_floor_area_weights => gfa_weights,
            :aggregate_gross_floor_area_weights => aggregated_gfa_weights,
            :location_id_gfa_weights => location_id_gfa_weights,
        ]
            isapprox(sum(values(val)), 1) ||
                @warn "`$(field)` for `$(scope)` doesn't add up to one!"
        end
        new(
            scope,
            num_buildings,
            avg_gfa_m2_per_building,
            hru_eff,
            inf_rate,
            sol_transm,
            ven_rate,
            win_U,
            structure_data,
            location_id_gfa_weights,
            shape_path,
            raster_path,
        )
    end
end


SpineDataType = Union{Real,TimeSeries,TimePattern,Map}


"""
    EnvelopeData(archetype::Object, data::ScopeData; mod::Module = @__MODULE__) <: BuildingDataType

Store the calculated dimensions of the different parts of the building envelope.

`EnvelopeData` is generated based on the `building_archetype` parameters
and the aggregated [`ScopeData`](@ref).

NOTE! The `mod` keyword changes from which Module data is accessed from
by the constructor, `@__MODULE__` by default.

This struct contains the following fields:
- `archetype::Object`: The [`building_archetype`](@ref) this envelope belongs to.
- `base_floor::NamedTuple`: Linear thermal bridge length [m] and surface area [m2] of the base floor.
- `exterior_wall::NamedTuple`: Linear thermal bridge length [m] and surface area [m2] of the load-bearing exterior walls.
- `light_exterior_wall::NamedTuple`: Linear thermal bridge length [m] and surface area [m2] of the light exterior walls.
- `light_partition_wall::NamedTuple`: Linear thermal bridge length [m] and one-sided surface area [m2] of the light partition walls.
- `partition_wall::NamedTuple`: Linear thermal bridge length [m] and one-sided surface area [m2] of the load-bearing partition walls.
- `roof::NamedTuple`: Linear thermal bridge length [m] and surface area [m2] of the roof.
- `separating_floor::NamedTuple`: Linear thermal bridge length [m] and one-sided surface area [m2] of the partition floors.
- `window::NamedTuple`: Linear thermal bridge length [m] and surface area [m2] of the windows.
- `total_structure_area_m2`: Total surface area of all the structures [m2].

The constructor calls the [`process_building_envelope`](@ref) function
and checks that the results are sensible.
"""
struct EnvelopeData <: BuildingDataType
    archetype::Object
    base_floor::NamedTuple{
        (:linear_thermal_bridge_length_m, :surface_area_m2),
        Tuple{Float64,Float64},
    }
    exterior_wall::NamedTuple{
        (:linear_thermal_bridge_length_m, :surface_area_m2),
        Tuple{Float64,Float64},
    }
    light_exterior_wall::NamedTuple{
        (:linear_thermal_bridge_length_m, :surface_area_m2),
        Tuple{Float64,Float64},
    }
    light_partition_wall::NamedTuple{
        (:linear_thermal_bridge_length_m, :surface_area_m2),
        Tuple{Float64,Float64},
    }
    partition_wall::NamedTuple{
        (:linear_thermal_bridge_length_m, :surface_area_m2),
        Tuple{Float64,Float64},
    }
    roof::NamedTuple{
        (:linear_thermal_bridge_length_m, :surface_area_m2),
        Tuple{Float64,Float64},
    }
    separating_floor::NamedTuple{
        (:linear_thermal_bridge_length_m, :surface_area_m2),
        Tuple{Float64,Float64},
    }
    window::NamedTuple{
        (:linear_thermal_bridge_length_m, :surface_area_m2),
        Tuple{Float64,Float64},
    }
    total_structure_area_m2::Float64
    """
        EnvelopeData(archetype::Object, data::ScopeData; mod::Module = @__MODULE__)

    Construct a new `EnvelopeData` based on the `archetype` and `data`.    
    """
    function EnvelopeData(archetype::Object, data::ScopeData; mod::Module=@__MODULE__)
        EnvelopeData(archetype, process_building_envelope(archetype, data; mod=mod)...)
    end
    function EnvelopeData(archetype::Object, args...)
        for (i, arg) in enumerate(args)
            all(values(arg) .>= 0) ||
                @warn "`$(fieldnames(EnvelopeData)[i])` for `$(archetype)` shouldn't be negative!"
        end
        new(archetype, args...)
    end
end


"""
    LoadsData(
        archetype::Object,
        scope::ScopeData;
        mod::Module = @__MODULE__,
    ) <: BuildingDataType

Store the domestic hot water demand and internal heat gains data.

The domestic hot water demand and internal gains are calculated based on the
provided base and GFA-scaling parameters.

NOTE! The `mod` keyword changes from which Module data is accessed from
by the constructor, `@__MODULE__` by default.

This struct contains the following fields:
- `domestic_hot_water_demand_W::SpineDataType`: Domestic hot water demand data in [W] for the building.
- `internal_heat_gains_W::SpineDataType`: Total internal heat gains data in [W] for the building.

The constructor calls the [`process_building_loads`](@ref) function and checks
that the results are sensible.
"""
struct LoadsData <: BuildingDataType
    archetype::Object
    domestic_hot_water_demand_W::SpineDataType
    internal_heat_gains_W::SpineDataType
    """
        LoadsData(
            archetype::Object,
            scope::ScopeData;
            mod::Module = @__MODULE__,
        )

    Construct a new `LoadsData` for the `archetype` based on the given data structs.
    """
    function LoadsData(archetype::Object, scope::ScopeData; mod::Module=@__MODULE__)
        dhw_demand, int_gains = process_building_loads(archetype, scope; mod=mod)
        LoadsData(archetype, dhw_demand, int_gains)
    end
    function LoadsData(archetype::Object, args...)
        for (i, arg) in enumerate(args)
            all(collect_leaf_values(arg) .>= 0) || @warn """
            `$(fieldnames(LoadsData)[i])` for `$(archetype)` shouldn't have negative values!
            $(count(values(arg) .< 0)) violations found, with a minimum value of $(minimum(values(arg))).
            """
        end
        new(archetype, args...)
    end
end


"""
    BuildingNodeData(
        archetype::Object,
        node::Object,
        scope::ScopeData,
        envelope::EnvelopeData,
        loads::LoadsData;
        mod::Module = @__MODULE__,
    ) <: BuildingDataType

Contains data about how the structures and systems are aggregated into nodes for the lumped-capacitance thermal model.

The `BuildingNodeData` struct aims to remain as human-readable as possible,
making it a high-level description for what the lumped-capacitance node contains.
Ultimately, `BuildingNodeData`s are further processed into [`AbstractNode`](@ref)s
for more convenient demand calculations as well as exporting into
energy-system-model-specific input data formats.

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

This struct contains the following fields:
- `building_node::Object`: The `building_node` definition used for this `BuildingNodeData`.
- `heating_set_point_K`: The heating set point for this node [K].
- `cooling_set_point_K`: 
- `thermal_mass_base_J_K::SpineDataType`: Optional user-defined base effective thermal mass in [J/K] of the temperature node.
- `thermal_mass_gfa_scaled_J_K::SpineDataType`: Optional user-defined gross-floor-area-scaling effective thermal mass in [J/m2K] of the temperature node.
- `thermal_mass_interior_air_and_furniture_J_K::Float64`: The effective thermal mass contribution of the interior air and furniture on this temperature node.
- `thermal_mass_structures_J_K::Float64`: The effective thermal mass contribution of included structures on this temperature node.
- `maximum_temperature_deviation_K::SpineDataType`: The maximum permitted temperature deviation above the set point [K].
- `minimum_temperature_deviation_K::SpineDataType`: The minimum permitted temperature deviation below the set point [K].
- `self_discharge_base_W_K::SpineDataType`: Optional user-defined base self-discharge rate in [W/K] of the temperature node.
- `self_discharge_gfa_scaled_W_K::SpineDataType`: Optional user-defined gross-floor-area-scaling self-discharge rate in [W/m2K] of the temperature node.
- `heat_transfer_coefficients_base_W_K::Dict{Object,SpineDataType}`: Optional user-defined base heat transfer coefficients between this node and other temperature nodes.
- `heat_transfer_coefficients_gfa_scaled_W_K::Dict{Object,SpineDataType}`: Optional user-defined gross-floor-area-scaling heat transfer coefficients between this node and other temperature nodes.
- `heat_transfer_coefficient_structures_interior_W_K::Float64`: The contribution of included structures on the heat transfer coefficient between this node and the interior air node.
- `heat_transfer_coefficient_structures_exterior_W_K::Float64`: The contribution of included structures on the heat transfer coefficients between this node and the ambient temperature.
- `heat_transfer_coefficient_structures_ground_W_K::Float64`: The contribution of included structures on the heat transfer coefficient between this node and the effective ground temperature.
- `heat_transfer_coefficient_windows_W_K::Float64`: Contribution of windows to the heat transfer coefficient from this node to the ambient air.
- `heat_transfer_coefficient_ventilation_and_infiltration_W_K::SpineDataType`: Contribution of infiltration and ventilation on the heat transfer coefficient between this node and the ambient air.
- `heat_transfer_coefficient_ventilation_and_infiltration_W_K_HRU_bypass::SpineDataType`: Contribution of infiltration and ventilation on the heat transfer coefficient between this node and the ambient air when HRU is bypassed.
- `heat_transfer_coefficient_thermal_bridges_W_K::Float64`: Contribution of linear thermal bridges on the heat transfer coefficient between this node and the ambient air.
- `domestic_hot_water_demand_W::SpineDataType`: Domestic hot water demand in [W] on this node.
- `internal_heat_gains_air_W::SpineDataType`: Convective part of internal heat gains on this node in [W].
- `internal_heat_gains_structures_W::SpineDataType`: Radiative part of internal heat gains on this node in [W].
- `radiative_envelope_sky_losses_W::SpineDataType`: Radiative heat losses to the sky from the exposed parts of the building envelope [W].
- `is_interior_node::Bool`: Flag indicating whether this node is the primary indoor air node.

The constructor calls the [`process_building_node`](@ref) function,
and checks the values are sensible.
"""
struct BuildingNodeData <: BuildingDataType
    archetype::Object
    building_node::Object
    heating_set_point_K::Union{Nothing,SpineDataType}
    cooling_set_point_K::Union{Nothing,SpineDataType}
    thermal_mass_base_J_K::SpineDataType
    thermal_mass_gfa_scaled_J_K::SpineDataType
    thermal_mass_interior_air_and_furniture_J_K::Float64
    thermal_mass_structures_J_K::Float64
    maximum_temperature_deviation_K::SpineDataType
    minimum_temperature_deviation_K::SpineDataType
    self_discharge_base_W_K::SpineDataType
    self_discharge_gfa_scaled_W_K::SpineDataType
    heat_transfer_coefficients_base_W_K::Dict{Object,SpineDataType}
    heat_transfer_coefficients_gfa_scaled_W_K::Dict{Object,SpineDataType}
    heat_transfer_coefficient_structures_interior_W_K::Float64
    heat_transfer_coefficient_structures_exterior_W_K::Float64
    heat_transfer_coefficient_structures_ground_W_K::Float64
    heat_transfer_coefficient_windows_W_K::Float64
    heat_transfer_coefficient_ventilation_and_infiltration_W_K::SpineDataType
    heat_transfer_coefficient_ventilation_and_infiltration_W_K_HRU_bypass::SpineDataType
    heat_transfer_coefficient_thermal_bridges_W_K::Float64
    domestic_hot_water_demand_W::SpineDataType
    internal_heat_gains_air_W::SpineDataType
    internal_heat_gains_structures_W::SpineDataType
    is_interior_node::Bool
    """
        BuildingNodeData(
            archetype::Object,
            node::Object,
            scope::ScopeData,
            envelope::EnvelopeData,
            loads::LoadsData;
            mod::Module = @__MODULE__,
        )

    Construct a new `BuildingNodeData` for `archetype` and `node`.
    """
    function BuildingNodeData(
        archetype::Object,
        node::Object,
        scope::ScopeData,
        envelope::EnvelopeData,
        loads::LoadsData;
        mod::Module=@__MODULE__
    )
        BuildingNodeData(
            archetype,
            node,
            process_building_node(archetype, node, scope, envelope, loads; mod=mod)...,
        )
    end
    function BuildingNodeData(
        archetype::Object,
        building_node::Object,
        heating_set_point_K::Union{Nothing,SpineDataType},
        cooling_set_point_K::Union{Nothing,SpineDataType},
        args...,
    )
        # Check heating and cooling set point types.
        if !isa(heating_set_point_K, typeof(cooling_set_point_K))
            @error """
            Heating and cooling set points both need to be given if either is!
            Check data for `$(archetype).$(building_node)`.
            """
        end
        # Check parameter values.
        for (i, arg) in enumerate(args)
            all(collect_leaf_values(arg) .>= 0) || @warn """
            `$(fieldnames(BuildingNodeData)[i+1])` for `$(building_node)` shouldn't have negative values!
            $(count(values(arg) .< 0)) violations found, with a minimum value of $(minimum(values(arg))).
            """
        end
        new(archetype, building_node, heating_set_point_K, cooling_set_point_K, args...)
    end
end


"""
    BuildingNodeNetwork::Dict{Object,BuildingNodeData}

`Dict` mapping [`BuildingNodeData`](@ref) to their corresponding `building_node` `Object`s.
"""
BuildingNodeNetwork = Dict{Object,BuildingNodeData}


"""
    WeatherData(
        archetype::Object,
        scope_data::ScopeData,
        envelope_data::EnvelopeData,
        building_nodes::BuildingNodeNetwork;
        ignore_year::Bool=false,
        repeat::Bool=false,
        save_layouts::Bool=false,
        resampling::Int=5,
        mod::Module=@__MODULE__,
        realization::Symbol=:realization
    ) <: BuildingDataType

Process and store the weather data for further calculations.

NOTE! The `mod` keyword changes from which Module data is accessed from
by the constructor, `@__MODULE__` by default. The `realization` scenario is
required for effective ground temperature calculations.

This struct contains the following fields:
- `archetype::Object`: The `building_archetype` object used to construct this `WeatherData`.
- `preliminary_heating_demand_W`: The preliminary aggregated air node heating demand calculated using PyPSA/atlite through ArBuWe.py.
- `preliminary_cooling_demand_W`: The preliminary aggregated air node cooling demand calculated using PyPSA/atlite through ArBuWe.py.
- `ambient_temperature_K::SpineDataType`: Average ambient temperature data in [K] for this archetype.
- `ground_temperature_K::SpineDataType`: Effective ground temperature data in [K] for this archetype.
- `total_effective_solar_irradiation_W_m2::SpineDataType`: The total effective solar irradiation data in [W/m2] for horizontal and vertical surfaces respectively.
- `heating_set_point_K`: The `TimeSeries` form indoor air heating set point used for the demand calculations.
- `cooling_set_point_K`: The `TimeSeries` form indoor air cooling set point used for the demand calculations.

Essentially, the constructor calls the [`process_weather`](@ref) function,
and checks that the resulting values are sensible.
"""
struct WeatherData <: BuildingDataType
    archetype::Object
    preliminary_heating_demand_W::SpineDataType
    preliminary_cooling_demand_W::SpineDataType
    ambient_temperature_K::SpineDataType
    ground_temperature_K::SpineDataType
    total_effective_solar_irradiation_W_m2::Dict{Symbol,SpineDataType}
    heating_set_point_K::SpineDataType
    cooling_set_point_K::SpineDataType
    """
        WeatherData(weather::Object; mod::Module = @__MODULE__)

    Construct a new `WeatherData` based on the given `weather` object.
    """
    function WeatherData(
        archetype::Object,
        scope_data::ScopeData,
        envelope_data::EnvelopeData,
        building_nodes::BuildingNodeNetwork;
        ignore_year::Bool=false,
        repeat::Bool=false,
        save_layouts::Bool=false,
        resampling::Int=5,
        mod::Module=@__MODULE__,
        realization::Symbol=:realization,
    )
        WeatherData(
            archetype,
            process_weather(
                archetype,
                scope_data,
                envelope_data,
                building_nodes;
                ignore_year=ignore_year,
                repeat=repeat,
                save_layouts=save_layouts,
                resampling=resampling,
                mod=mod,
                realization=realization,
            )...,
        )
    end
    function WeatherData(archetype::Object, args...)
        for (i, arg) in enumerate(args)
            all(collect_leaf_values(arg) .>= 0) ||
                @warn "`$(fieldnames(WeatherData)[i])` for `$(archetype)` shouldn't have negative values!"
        end
        new(archetype, args...)
    end
end


"""
    BuildingProcessData(
        archetype::Object,
        process::Object,
        scope::ScopeData,
        weather::WeatherData;
        mod::Module = @__MODULE__,
    ) <: BuildingDataType

Aggregate building systems into processes for the lumped-capacitance thermal model.

The `BuildingProcessData` struct aims to remain as human-readable as possible,
making it a high-level description of the properties of a process
in the lumped-capacitance thermal model.

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

This struct contains the following fields:
- `building_process::Object`: The `building_process` definition for this `BuildingProcessData`.
- `system_link_nodes::Vector{Object}`: The energy system nodes used to connect the buildings to the energy system at large.
- `coefficient_of_performance::SpineDataType`: The coefficient of performance of the process.
- `coefficient_of_performance_mode::Symbol`: The mode of the process, either `:heating` or `:cooling`.
- `maximum_power_base_W::Dict{Tuple{Object,Object},SpineDataType}`: User-defined base maximum power flows in [W] between this process and the nodes.
- `maximum_power_gfa_scaled_W::Dict{Tuple{Object,Object},SpineDataType}`: User-defined gross-floor-area-scaling maximum power flows in [W] between this process and the nodes.
- `maximum_flows_W::Dict{Tuple{Object,Object},SpineDataType}`: The total maximum flows to/from this process [W], for modelling convenience.

The constructor calls the [`process_building_system`](@ref) function.
"""
struct BuildingProcessData <: BuildingDataType
    archetype::Object
    building_process::Object
    system_link_nodes::Vector{Object}
    coefficient_of_performance::SpineDataType
    coefficient_of_performance_mode::Symbol
    maximum_power_base_W::Dict{Tuple{Object,Object},SpineDataType}
    maximum_power_gfa_scaled_W::Dict{Tuple{Object,Object},SpineDataType}
    maximum_flows_W::Dict{Tuple{Object,Object},SpineDataType}
    """
        BuildingProcessData(
            archetype::Object,
            process::Object,
            scope::ScopeData,
            weather::WeatherData;
            mod::Module = @__MODULE__,
        )

    Constructs a new `BuildingProcessData` for `archetype` and `process`.
    """
    function BuildingProcessData(
        archetype::Object,
        process::Object,
        scope::ScopeData,
        weather::WeatherData;
        mod::Module=@__MODULE__
    )
        new(
            archetype,
            process,
            process_building_system(archetype, process, scope, weather; mod=mod)...,
        )
    end
end


"""
    AbstractNode(
        building_node_network::BuildingNodeNetwork,
        node::Object,
        weather::WeatherData,
    ) <: BuildingDataType

Contain parameters defining a `node` in a large-scale-energy-system-model-agnostic manner.

TODO: Revise documentation, rename to FlexibilityNode?

Essentially, a `node` is a point in a commodity network where commodity balance is observed.
`nodes` can have a *state*, which represents accumulated commodities at the point.
The state of a `node` can "bleed" either outside the model scope
via the `self_discharge_coefficient_W_K`, or into another `nodes`
via the `heat_transfer_coefficients_W_K`. The `external_load_W` represents
uncontrollable external influence affecting the `node`,
e.g. commodity demand or gains.

This struct contains the following fields:
- `building_node::Object`: The `building_node` definition this `AbstractNode` depicts.
- `thermal_mass_Wh_K::SpineDataType`: The effective thermal mass of this node in [Wh/K].
- `self_discharge_coefficient_W_K::SpineDataType`: The self-discharge coefficient in [W/K] from this node.
- `heat_transfer_coefficients_W_K::Dict{Object,SpineDataType}`: The heat transfer coefficients between this node and other nodes in [W/K].
- `maximum_temperature_K::SpineDataType`: Maximum permitted temperature of the node in [K].
- `minimum_temperature_K::SpineDataType`: Minimum permitted temperature of the node in [K].
- `is_interior_node::Bool`: A flag indicating whether this node is the primary interior air node.
- `is_dhw::Bool`: A flag indicating whether this node is the primary DHW node.

The constructor calls the [`process_abstract_node`](@ref) function.
"""
struct AbstractNode <: BuildingDataType
    archetype::Object
    building_node::Object
    heating_set_point_K::Union{Nothing,SpineDataType}
    cooling_set_point_K::Union{Nothing,SpineDataType}
    maximum_temperature_deviation_K::SpineDataType
    minimum_temperature_deviation_K::SpineDataType
    thermal_mass_Wh_K::SpineDataType
    self_discharge_coefficient_W_K::SpineDataType
    heat_transfer_coefficients_W_K::Dict{Object,SpineDataType}
    external_load_W::SpineDataType
    is_interior_node::Bool
    is_dhw::Bool
    """
        AbstractNode(
            building_node_network::BuildingNodeNetwork,
            node::Object,
        )

    Create a new `AbstractNode` corresponding to `node` based on the given data structs.
    """
    function AbstractNode(
        archetype::Object,
        scope::ScopeData,
        envelope::EnvelopeData,
        building_node_network::BuildingNodeNetwork,
        weather::WeatherData,
        node::Object;
        mod::Module=@__MODULE__
    )
        new(
            archetype,
            node,
            process_abstract_node(
                archetype,
                scope,
                envelope,
                building_node_network,
                weather,
                node;
                mod=mod,
            )...,
        )
    end
end


"""
    AbstractNodeNetwork::Dict{Object,AbstractNode}

`Dict` mapping [`AbstractNode`](@ref)s to their corresponding `building_node`s. 
"""
AbstractNodeNetwork = Dict{Object,AbstractNode}


"""
    ArchetypeBuilding(
        archetype::Object,
        scope_data::ScopeData;
        save_layouts::Bool=false,
        mod::Module=@__MODULE__
    )

Contains data representing a single archetype building.

The `ArchetypeBuilding` struct stores the information about the objects
used in its construction, the aggregated statistical and structural properties,
as well as the [`BuildingNodeData`](@ref) and [`BuildingProcessData`](@ref).
The contents of the `ArchetypeBuilding` are intended to be as human-readable
as possible to allow for inspecting the contents individually
for debugging purposes.

NOTE! The `mod` keyword changes from which Module data is accessed from
by the constructor, `@__MODULE__` by default.

This struct contains the following fields:
- `archetype::Object`: The `building_archetype` object corresponding to this `ArchetypeBuilding`.
- `scope::Object`: The defined `building_scope` for this archetype.
- `fabrics::Object`: The defined `building_fabrics` for this archetype.
- `systems::Object`: The defined `building_systems` for this archetype.
- `loads::Object`: The defined `building_loads` for this archetype.
- `scope_data::ScopeData`: The processed `building_scope` data for this archetype.
- `envelope_data::EnvelopeData`: The processed envelope properties of this archetype.
- `building_nodes::BuildingNodeNetwork`: The temperature node network depicting this archetype.
- `building_processes::Dict{Object,BuildingProcessData}`: The processes in this archetype.
- `loads_data::LoadsData`: The loads defined for this archetype.
- `weather_data::WeatherData`: The processed weather data for this archetype.
- `abstract_nodes::AbstractNodeNetwork`: The processed [`AbstractNode`](@ref)s depicting this archetype.

The constructor performs the following steps:
1. Fetch and create the corresponding [`ScopeData`](@ref).
2. Fetch and create the corresponding [`WeatherData`](@ref).
3. Form the [`EnvelopeData`](@ref).
4. Process the [`LoadsData`](@ref).
5. Process the temperature nodes using the [`create_building_node_network`](@ref) function.
6. Process the [`WeatherData`](@ref).
6. Create the [`BuildingProcessData`](@ref) for the HVAC system components.
7. Process the abstract temperature nodes using the [`create_abstract_node_network`](@ref) function based on the [`BuildingNodeNetwork`](@ref).
8. Construct the final `ArchetypeBuilding`.
"""
struct ArchetypeBuilding
    archetype::Object
    scope::Object
    fabrics::Object
    systems::Object
    loads::Object
    scope_data::ScopeData
    envelope_data::EnvelopeData
    building_nodes::BuildingNodeNetwork
    building_processes::Dict{Object,BuildingProcessData}
    loads_data::LoadsData
    weather_data::WeatherData
    abstract_nodes::AbstractNodeNetwork
    """
        ArchetypeBuilding(
            archetype::Object;
            mod::Module = @__MODULE__,
            realization::Symbol = :realization,
        )

    Create a new `ArchetypeBuilding` for the given `archetype`.
    """
    function ArchetypeBuilding(
        archetype::Object;
        save_layouts::Bool=false,
        mod::Module=@__MODULE__,
        realization::Symbol=:realization,
    )
        if length(mod.building_archetype__building_scope(building_archetype=archetype)) !=
           1
            @error "`$(archetype)` should have exactly one `building_scope` defined!"
        end
        scope_data = ScopeData(
            only(mod.building_archetype__building_scope(building_archetype=archetype));
            mod=mod,
        )
        # Create the ArchetypeBuilding using the latter constructor
        ArchetypeBuilding(
            archetype,
            scope_data;
            save_layouts=save_layouts,
            mod=mod,
            realization=realization,
        )
    end
    function ArchetypeBuilding(
        archetype::Object,
        scope_data::ScopeData;
        save_layouts::Bool=false,
        mod::Module=@__MODULE__,
        realization::Symbol=:realization,
    )
        # Fetch the definitions related to the archetype.
        scope = scope_data.building_scope
        fabrics =
            only(mod.building_archetype__building_fabrics(building_archetype=archetype))
        systems =
            only(mod.building_archetype__building_systems(building_archetype=archetype))
        loads = only(mod.building_archetype__building_loads(building_archetype=archetype))

        # Process the data related to the archetype.
        envelope_data = EnvelopeData(archetype, scope_data; mod=mod)
        loads_data = LoadsData(archetype, scope_data; mod=mod)
        building_node_network = create_building_node_network(
            archetype,
            fabrics,
            systems,
            scope_data,
            envelope_data,
            loads_data;
            mod=mod,
        )
        weather_data = WeatherData(
            archetype,
            scope_data,
            envelope_data,
            building_node_network;
            save_layouts=save_layouts,
            mod=mod,
        )
        building_processes = Dict(
            process => BuildingProcessData(
                archetype,
                process,
                scope_data,
                weather_data;
                mod=mod,
            ) for process in
            mod.building_systems__building_process(building_systems=systems)
        )

        # Process the abstract nodes and processes.
        abstract_nodes = create_abstract_node_network(
            archetype,
            scope_data,
            envelope_data,
            building_node_network,
            weather_data;
            mod=mod,
        )

        # Create the ArchetypeBuilding
        new(
            archetype,
            scope,
            fabrics,
            systems,
            loads,
            scope_data,
            envelope_data,
            building_node_network,
            building_processes,
            loads_data,
            weather_data,
            abstract_nodes,
        )
    end
end


abstract type ModelInput end


"""
    ArchetypeBuildingResults(
        archetype::ArchetypeBuilding;
        free_dynamics::Bool = false,
        initial_temperatures::Union{Nothing,Dict{Object,Float64}} = nothing,
        mod::Module = @__MODULE__,
        realization::Symbol = :realization,
    ) <: BuildingDataType

Store the temperature and HVAC demand results for the `archetype` building.

TODO: Revise documentation!

The `free_dynamics` keyword can be used to force the calculations to ignore
heating/cooling set points, while the `initial_temperatures` keyword
can be used to fix the initial temperatures for the simulation.
The `realization` keyword is used to select the true data from potentially
stochastic input.

NOTE! The `mod` keyword changes from which Module data is accessed from
by the constructor, `@__MODULE__` by default.

This struct contains the following fields:
- `archetype::ArchetypeBuilding`: The [`ArchetypeBuilding`](@ref) for which the results were calculated.
- `free_dynamics::Bool`: Flag whether or not to ignore set point temperatures for free temperature dynamics.
- `initial_temperatures::Dict{Object,Float64}`: The initial temperatures used for the results.
- `temperatures::Dict{Object,SpineDataType}`: The resulting node temperatures in [K].
- `hvac_demand::Dict{Object,SpineDataType}`: The HVAC demand required to keep the temperature nodes within the permitted limits for each node.
- `hvac_consumption::Dict{Object,SpineDataType}`: The estimated energy consumption of the HVAC equipment required to fulfill the HVAC demand.

The constructor performs the following steps:
1. Solve the initial temperatures, node temperatures, and HVAC demand using the [`solve_heating_demand`](@ref) function.
2. Solve the HVAC consumption using the [`solve_consumption`](@ref) function.
3. Return the `ArchetypeBuildingResults` using the calculated values.
"""
struct ArchetypeBuildingResults <: BuildingDataType
    archetype::ArchetypeBuilding
    temperatures_K::Dict{Object,SpineDataType}
    heating_demand_kW::Dict{Object,SpineDataType}
    cooling_demand_kW::Dict{Object,SpineDataType}
    hvac_consumption_kW::Dict{Object,SpineDataType}
    heating_correction_W::SpineDataType
    cooling_correction_W::SpineDataType
    """
        ArchetypeBuildingResults(
            archetype::ArchetypeBuilding;
            mod::Module = @__MODULE__,
            realization::Symbol = :realization,
        )

    Construct a new `ArchetypeBuildingResults` by solving the HVAC demand.    
    """
    function ArchetypeBuildingResults(
        archetype::ArchetypeBuilding;
        mod::Module=@__MODULE__,
        realization::Symbol=:realization,
    )
        temperatures_K,
        heating_demand_kW,
        cooling_demand_kW,
        heating_correction_W,
        cooling_correction_W = solve_heating_demand(archetype; realization=realization)
        hvac_consumption_kW =
            solve_consumption(archetype, heating_demand_kW, cooling_demand_kW; mod=mod)
        new(
            archetype,
            temperatures_K,
            heating_demand_kW,
            cooling_demand_kW,
            hvac_consumption_kW,
            heating_correction_W,
            cooling_correction_W,
        )
    end
end

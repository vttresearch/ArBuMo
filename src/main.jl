#=
    main.jl

Contains functions for the main program `process_archetype_buildings.jl`.
=#

"""
    run_input_data_tests(mod::Module = @__MODULE__)

Runs input data tests for the Datastore loaded to module `mod`, `@__MODULE__` by default.

Essentially performs the following steps:
1. Call [`run_object_class_tests`](@ref)
2. Call [`run_parameter_tests`](@ref)
3. Call [`run_structure_type_tests`](@ref)
"""
function run_input_data_tests(mod::Module=@__MODULE__)
    @time @testset "Datastore tests" begin
        run_object_class_tests(mod)
        run_parameter_tests(mod)
        run_structure_type_tests(mod)
    end
end


"""
    archetype_building_processing(
        mod::Module=@__MODULE__;
        save_layouts::Bool=false,
        realization::Symbol=:realization
    )

Process the [`ScopeData`](@ref) and [`ArchetypeBuilding`](@ref) objects.

Essentially, processes all the necessary information for [`ArchetypeBuilding`](@ref)
creation, and returns the `scope_data_dictionary`, `weather_data_dictionary`,
and `archetype_dictionary` for examining the processed data.
If `save_layouts == true`, diagnostic figures of the weather aggregation
layouts are saved into `figs/`. The `mod` keyword changes from which
Module data is accessed from, `@__MODULE__` by default.
The `realization` keyword is used to indicate the true data from potentially
stochastic input.

This function performs the following steps:
1. Construct the [`ScopeData`](@ref) for each defined [building\\_archetype\\_\\_building_scope](@ref), and store in the `scope_data_dictionary`.
2. Use the `scope_data_dictionary` to construct the [`ArchetypeBuilding`](@ref) for all defined archetypes, and store them in `archetype_dictionary`.
3. Return `scope_data_dictionary` and `archetype_dictionary`.
"""
function archetype_building_processing(
    mod::Module=@__MODULE__;
    save_layouts::Bool=false,
    realization::Symbol=:realization,
)
    # Process relevant `ScopeData` objects.
    @info "Processing `building_scope` objects into `ScopeData` for `scope_data_dictionary`..."
    @time scope_data_dictionary = Dict(
        archetype => ScopeData(scope; mod=mod) for
        (archetype, scope) in mod.building_archetype__building_scope()
    )

    # Process `ArchetypeBuilding` objects.
    @info "Processing `building_archetype` objects into `ArchetypeBuilding` for `archetype_dictionary`..."
    @time archetype_dictionary = Dict(
        archetype => ArchetypeBuilding(
            archetype,
            scope_data_dictionary[archetype];
            save_layouts=save_layouts,
            mod=mod,
            realization=realization,
        ) for archetype in mod.building_archetype()
    )

    # Return the dictionaries of interest
    return scope_data_dictionary, archetype_dictionary
end


"""
    solve_archetype_building_hvac_demand(
        archetype_dictionary::Dict{Object,ArchetypeBuilding};
        mod::Module=@__MODULE__,
        realization::Symbol=:realization
    )

Solve the [`ArchetypeBuilding`](@ref) heating and cooling demand.

NOTE! The `mod` keyword changes from which Module data is accessed from
by the constructor, `@__MODULE__` by default. The `realization` keyword
is used to denote the true data from potentially stochastic input.

Essentially creates the `archetype_results_dictionary` by constructing
the [`ArchetypeBuildingResults`](@ref) for each entry in the `archetype_dictionary`.
"""
function solve_archetype_building_hvac_demand(
    archetype_dictionary::Dict{Object,ArchetypeBuilding};
    mod::Module=@__MODULE__,
    realization::Symbol=:realization,
)
    # Heating/cooling demand calculations.
    @info "Calculating heating/cooling demand..."
    @time archetype_results_dictionary = Dict(
        archetype => ArchetypeBuildingResults(
            archetype_building;
            mod=mod,
            realization=realization,
        ) for (archetype, archetype_building) in archetype_dictionary
    )

    # Return the results dictionary
    return archetype_results_dictionary
end


"""
    initialize_result_classes!(mod::Module)

Initialize `RelationshipClass`es for storing heating and HVAC demand results in `mod`.

Note that this function modifies `mod` directly!
"""
function initialize_result_classes!(mod::Module)
    # Initialize archetype results
    results__building_archetype = RelationshipClass(
        :results__building_archetype,
        [:building_archetype],
        Array{RelationshipLike,1}(),
        Dict{RelationshipLike,Dict{Symbol,SpineInterface.ParameterValue}}(),
        Dict(
            param => parameter_value(nothing) for param in [
                :number_of_buildings,
                :average_gross_floor_area_per_building_m2,
                :ambient_temperature_K,
                :ground_temperature_K,
                :preliminary_heating_demand_W,
                :preliminary_cooling_demand_W,
                :heating_correction_W,
                :cooling_correction_W,
            ]
        ),
    )
    # Create the associated parameters
    number_of_buildings = Parameter(:number_of_buildings, [results__building_archetype])
    average_gross_floor_area_per_building_m2 =
        Parameter(:average_gross_floor_area_per_building_m2, [results__building_archetype])
    ambient_temperature_K = Parameter(:ambient_temperature_K, [results__building_archetype])
    ground_temperature_K = Parameter(:ground_temperature_K, [results__building_archetype])
    preliminary_heating_demand_W =
        Parameter(:preliminary_heating_demand_W, [results__building_archetype])
    preliminary_cooling_demand_W =
        Parameter(:preliminary_cooling_demand_W, [results__building_archetype])
    heating_correction_W = Parameter(:heating_correction_W, [results__building_archetype])
    cooling_correction_W =
        Parameter(:preliminary_heating_demand_W, [results__building_archetype])

    # Initialize archetype node results
    results__building_archetype__building_node = RelationshipClass(
        :results__building_archetype__building_node,
        [:building_archetype, :building_node],
        Array{RelationshipLike,1}(),
        Dict{ObjectLike,Dict{Symbol,SpineInterface.ParameterValue}}(),
        Dict(
            param => parameter_value(nothing) for
            param in [:temperature_K, :heating_demand_kW, :cooling_demand_kW]
        ),
    )
    # Create the associated parameters
    temperature_K = Parameter(:temperature_K, [results__building_archetype__building_node])
    heating_demand_kW =
        Parameter(:heating_demand_kW, [results__building_archetype__building_node])
    cooling_demand_kW =
        Parameter(:cooling_demand_kW, [results__building_archetype__building_node])

    # Initialize process results
    results__building_archetype__building_process = RelationshipClass(
        :results__building_archetype__building_process,
        [:building_archetype, :building_process],
        Array{RelationshipLike,1}(),
        Dict{ObjectLike,Dict{Symbol,SpineInterface.ParameterValue}}(),
        Dict(
            :hvac_consumption_per_building_kW => parameter_value(nothing),
            :hvac_consumption_MW => parameter_value(nothing),
        ),
    )
    # Create the associated parameter
    hvac_consumption_per_building_kW = Parameter(
        :hvac_consumption_per_building_kW,
        [results__building_archetype__building_process],
    )
    hvac_consumption_MW =
        Parameter(:hvac_consumption_MW, [results__building_archetype__building_process])

    # Initialize system link node results
    results__system_link_node = ObjectClass(
        :results__system_link_node,
        Array{ObjectLike,1}(),
        Dict{ObjectLike,Dict{Symbol,SpineInterface.ParameterValue}}(),
        Dict(:total_consumption_MW => parameter_value(nothing)),
    )
    # Create the assosicated parameter
    total_consumption_MW = Parameter(:total_consumption_MW, [results__system_link_node])

    # Evaluate the relationship classes and parameters to the desired module.
    @eval mod begin
        results__building_archetype = $results__building_archetype
        results__building_archetype__building_node =
            $results__building_archetype__building_node
        results__building_archetype__building_process =
            $results__building_archetype__building_process
        results__system_link_node = $results__system_link_node
        number_of_buildings = $number_of_buildings
        average_gross_floor_area_per_building_m2 = $average_gross_floor_area_per_building_m2
        ambient_temperature_K = $ambient_temperature_K
        ground_temperature_K = $ground_temperature_K
        preliminary_heating_demand_W = $preliminary_heating_demand_W
        preliminary_cooling_demand_W = $preliminary_cooling_demand_W
        heating_correction_W = $heating_correction_W
        cooling_correction_W = $cooling_correction_W
        temperature_K = $temperature_K
        heating_demand_kW = $heating_demand_kW
        cooling_demand_kW = $cooling_demand_kW
        hvac_consumption_per_building_kW = $hvac_consumption_per_building_kW
        hvac_consumption_MW = $hvac_consumption_MW
        total_consumption_MW = $total_consumption_MW
    end

    # Return the handles for the relationship classes for future reference.
    return results__building_archetype,
    results__building_archetype__building_node,
    results__building_archetype__building_process,
    results__system_link_node
end


"""
    add_results!(
        results__building_archetype::RelationshipClass,
        results__building_archetype__building_node::RelationshipClass,
        results__building_archetype__building_process::RelationshipClass,
        results__system_link_node::ObjectClass,
        results_dictionary::Dict{Object,ArchetypeBuildingResults};
        mod::Module = @__MODULE__
    )

    Add results from `results_dictionary` into the result `RelationshipClass`es.

    NOTE! The `mod` keyword changes from which Module data is accessed from,
    `@__MODULE__` by default.
"""
function add_results!(
    results__building_archetype::RelationshipClass,
    results__building_archetype__building_node::RelationshipClass,
    results__building_archetype__building_process::RelationshipClass,
    results__system_link_node::ObjectClass,
    results_dictionary::Dict{Object,ArchetypeBuildingResults};
    mod::Module=@__MODULE__
)
    # Collect `ArchetypeBuildingResults`
    results = values(results_dictionary)

    # Add `results__building_archetype` results.
    add_relationship_parameter_values!(
        results__building_archetype,
        Dict(
            (building_archetype=r.archetype.archetype,) => Dict(
                :number_of_buildings =>
                    parameter_value(r.archetype.scope_data.number_of_buildings),
                :average_gross_floor_area_per_building_m2 => parameter_value(
                    r.archetype.scope_data.average_gross_floor_area_m2_per_building,
                ),
                :ambient_temperature_K =>
                    parameter_value(r.archetype.weather_data.ambient_temperature_K),
                :ground_temperature_K =>
                    parameter_value(r.archetype.weather_data.ground_temperature_K),
                :preliminary_heating_demand_W => parameter_value(
                    r.archetype.weather_data.preliminary_heating_demand_W,
                ),
                :preliminary_cooling_demand_W => parameter_value(
                    r.archetype.weather_data.preliminary_cooling_demand_W,
                ),
                :heating_correction_W => parameter_value(r.heating_correction_W),
                :cooling_correction_W => parameter_value(r.cooling_correction_W),
            ) for r in results
        ),
    )

    # Add `results__building_archetype__building_node` results.
    add_relationship_parameter_values!(
        results__building_archetype__building_node,
        Dict(
            (building_archetype=r.archetype.archetype, building_node=node) => Dict(
                :temperature_K => parameter_value(r.temperatures_K[node]),
                :heating_demand_kW => parameter_value(r.heating_demand_kW[node]),
                :cooling_demand_kW => parameter_value(r.cooling_demand_kW[node]),
            ) for r in results for node in keys(r.temperatures_K)
        ),
    )

    # Add `results__building_archetype__building_process` results.
    add_relationship_parameter_values!(
        results__building_archetype__building_process,
        Dict(
            (building_archetype=r.archetype.archetype, building_process=process) =>
                Dict(
                    :hvac_consumption_per_building_kW =>
                        parameter_value(r.hvac_consumption_kW[process]),
                    :hvac_consumption_MW => parameter_value(
                        r.hvac_consumption_kW[process] / 1e3 *
                        r.archetype.scope_data.number_of_buildings,
                    ),
                ) for r in results for process in keys(r.hvac_consumption_kW)
        ),
    )

    # Add `results__system_link_node` results.
    add_object_parameter_values!(
        results__system_link_node,
        Dict(
            sys_link_n => Dict(
                :total_consumption_MW => parameter_value(
                    sum(
                        mod.hvac_consumption_MW(
                            building_archetype=arch,
                            building_process=p,
                        ) for
                        p in mod.results__building_archetype__building_process(
                            building_archetype=arch,
                        ) if p in mod.building_process__direction__building_node(
                            direction=mod.direction(:from_node),
                            building_node=sys_link_n,
                        )
                    ),
                ),
            ) for (arch, sys_link_n) in mod.building_archetype__system_link_node(
                building_archetype=collect(keys(results_dictionary));
                _compact=false,
            )
        ),
    )

    # Return the results of interest
    return results__building_archetype,
    results__building_archetype__building_node,
    results__building_archetype__building_process,
    results__system_link_node
end

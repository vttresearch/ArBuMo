#=
    solve_demand.jl

Functions for solving the heating/cooling demands of `ArchetypeBuilding`s.
=#


"""
    solve_heating_demand(
        archetype::ArchetypeBuilding,
        free_dynamics::Bool,
        initial_temperatures::Union{Nothing,Dict{Object,Float64}};
        realization::Symbol = :realization,
    )

Solve the heating/cooling demand of the `archetype`.

TODO: Revise documentation.

Note that this function calculates the "final energy demand" of the archetype
building, and not the energy consumption of it's HVAC systems.
Furthermore, the calculations are deterministic, with `realization` defining
the true data from potentially stochastic input.
See the [`solve_consumption`](@ref) function for that.
Essentially, performs the following steps:
1. Check external load data and [`determine_temporal_structure`](@ref).
2. [`form_and_invert_dynamics_matrix`](@ref) for the free temperature dynamics.
3. Initialize external load an thermal mass vectors using [`initialize_rhs`](@ref).
4. Initialize temperature and temperature limit vectors using [`initialize_temperatures`](@ref).
5. Solve the heating demand using [`solve_heating_demand_loop`](@ref).
6. Rearrange the solution into `Dict`s and return them.

Uses an extremely simple rule-based control to solve the heating/cooling
demand of the archetype building. The controller intervenes
whenever node temperatures would deviate from permitted limits,
and provides the required energy input to maintain the system at the limit.

The building dynamics are discretized using implicit *(backwards)* Euler,
mainly for consistency with our existing energy system modelling tools
like Backbone or SpineOpt. In principle, I believe the system could be solved
analytically similar to my Master's Thesis, if better accuracy would be desired:
*Energy Management in Households with Coupled Photovoltaics and Electric Vehicles, Topi Rasku, 2015, Aalto University School of Science*.

The idea of solving heating demand calculations can be as follows,
starting from the energy balance equation for node `n`
```math
C_n \\frac{dT_n(t)}{dt} = - \\rho_n T_n(t) + \\sum_{m \\in N} \\left[ H_{n,m} \\left( T_m(t) - T_n(t) \\right) \\right] + \\Phi_n(t),
```
where `C_n` is the heat capacity of node `n`,
`T_n(t)` is the time-dependent temperature of node `n` at time `t`,
`ρ_n` is the self-discharge from node `n`,
`N` is the set of temperature nodes in the lumped-capacitance model of the building,
`H_n,m` is the heat transfer coefficient between nodes `n` and `m`,
and `Φ_n(t)` is the time-dependent total external heat load on node `n`.
Using the implicit Euler discretization, the above can be cast into
```math
\\left( \\frac{C_n}{\\Delta t} + \\rho_n + \\sum_{m \\in N} H_{n,m} \\right) T_{n,t} - \\sum_{m \\in N} \\left[ H_{n,m} T_{m,t} \\right] = \\Phi_{n,t} + \\frac{C_n}{\\Delta t} T_{n,t-\\Delta t},
```
where `Δt` is the length of the discretized time step.
Since we always know the temperatures on the previous time step `t-Δt`,
the above can be expressed in matrix form and solved as
```math
\\bm{A} \\hat{T} = \\hat{\\Phi}, \\\\
\\hat{T} = \\bm{A}^{-1} \\hat{\\Phi},
```
where `A` is the so-called *dynamics matrix*, 
`T` is the current temperature vector,
and `Φ` is the right-hand side vector, containing the effect of external loads
and previous temperatures.

The above is used to calculate the temperatures of the nodes on each subsequent
time step. However, when any of the node temperatures would violate the defined
minimum and maximum permitted temperatures, that temperature variable is instead
fixed to the violated boundary, moved to the right-hand side,
and replaced with a heating/cooling demand variable `ϕ_m` instead.
This results in a slightly modified problem to be solved
```math
\\hat{\\phi} = \\left( \\bm{A} - \\sum_{m \\in M}[\\bm{A}_{m} + \\bm{I}_{m}] \\right)^{-1} \\left( \\hat{\\Phi} - \\sum_{m \\in M}[\\hat{A}_{m} T'_m] \\right),
```
where `ϕ` is the modified temperature vector with the fixed temperature replaced
with the heating/cooling demand variable,
`m ∈ M` are the nodes that would violate their permitted bounds,
and are therefore fixed at the boundary `T'_m`,
`A_m` represents a selection of column `m` from the matrix `A`,
and `I_m` represents column `m` from an identity matrix.
Please note that there are both matrix and vector selections of `A_m`,
where the matrix selection preserves the dimensions with filling zeroes,
while the vector selection is essentially only the selected column in vector form.
"""
function solve_heating_demand(
    archetype::ArchetypeBuilding;
    realization::Symbol=:realization
)
    # Categorize nodes based on their role.
    (air_node, air_node_data) = only(
        filter(
            pair -> pair[2].is_interior_node, archetype.abstract_nodes
        )
    )
    (dhw_node, dhw_node_data) = only(
        filter(
            pair -> pair[2].is_dhw, archetype.abstract_nodes
        )
    )
    set_nodes = filter(
        pair -> !isnothing(pair[2].heating_set_point_K), archetype.abstract_nodes
    )
    free_nodes = Dict(setdiff(archetype.abstract_nodes, set_nodes)...)

    # Determine the temporal structure
    indices, delta_t = determine_temporal_structure(
        archetype;
        realization=realization
    )
    zero_ts = TimeSeries(indices, zeros(size(indices)))

    # Estimated node temperatures based on heating and cooling demand ratio.
    hc_ratio = (
        archetype.weather_data.preliminary_heating_demand_W / (
            archetype.weather_data.preliminary_heating_demand_W +
            archetype.weather_data.preliminary_cooling_demand_W
        )
    )
    replace!(x -> isnan(x) ? 0.5 : x, hc_ratio.values)

    temperatures_K = Dict(
        node => zero_ts +
                hc_ratio * node_data.heating_set_point_K +
                (1 - hc_ratio) * node_data.cooling_set_point_K
        for (node, node_data) in set_nodes
    )

    # Calculate the free node temperatures based on set points.
    solve_free_node_temperature_dynamics!(
        temperatures_K,
        free_nodes,
        set_nodes,
        indices,
        delta_t
    )

    # Calculate the heating demand for the indoor air node
    heating_demand_kW,
    cooling_demand_kW,
    heating_correction_W,
    cooling_correction_W = calculate_final_heating_demand(
        archetype,
        temperatures_K,
        air_node,
        free_nodes
    )

    # Estimated node temperatures based on heating and cooling demand ratio.
    hc_ratio = heating_demand_kW / (heating_demand_kW + cooling_demand_kW)
    replace!(x -> isnan(x) ? 0.5 : x, hc_ratio.values)

    # Solve DHW node demand.
    dhw_demand_kW = solve_dhw_demand(
        archetype,
        dhw_node_data,
        temperatures_K,
        hc_ratio
    ) # Scaling to kWh internally within the function!

    # Initialize the heating and cooling demand result dictionaries.
    heating_demand_dict_kW = Dict(
        node => zero_ts for node in keys(archetype.abstract_nodes)
    )
    cooling_demand_dict_kW = Dict(
        node => zero_ts for node in keys(archetype.abstract_nodes)
    )
    # Save the results of interest into the result dictionaries
    heating_demand_dict_kW[air_node] = heating_demand_kW
    heating_demand_dict_kW[dhw_node] = dhw_demand_kW
    cooling_demand_dict_kW[air_node] = cooling_demand_kW

    return temperatures_K,
    heating_demand_dict_kW,
    cooling_demand_dict_kW,
    heating_correction_W,
    cooling_correction_W
end


"""
    determine_temporal_structure(
        archetype::ArchetypeBuilding;
        realization::Symbol = :realization,
    )

Check that `external_load_W` timeseries are consistent in the `AbstractNodeNetwork`,
and determine the time series indices and the `delta_t`.

TODO: Revise documentation.

Note that the time series need to have a constant `delta_t` in order for the
dynamic matrix to be time-invarying, speeding up the solving process significantly.
The `realization` keyword is necessary to indicate the true data from potentially
stochastic input.
"""
function determine_temporal_structure(
    archetype::ArchetypeBuilding;
    realization::Symbol=:realization
)
    # Check that all nodes have identical `external_load_W` time series indices.
    indices =
        keys(
            parameter_value(first(archetype.abstract_nodes)[2].external_load_W)(
                scenario=realization,
            )
        )
    if !all(
        keys(parameter_value(n.external_load_W)(scenario=realization)) == indices for
        (k, n) in archetype.abstract_nodes
    )
        return @error """
        `external_load_W` time series are indexed different for `abstract_nodes`
        of `archetype_building` `$(archetype)`!
        """
    end

    # Indices must be a Vector{DateTime}, 24-hours simulated by default.
    if !isa(indices, Vector{DateTime})
        indices = [DateTime(2) + Hour(i) for i in 0:23]
    end

    # Calculate the delta t in hours, all time steps need to have constant value.
    delta_t = getfield.(Hour.(diff(indices)), :value)
    if !all(delta_t .== first(delta_t))
        return @error """
        `external_load_W` time series of `archetype` `$(archetype)` must have
        a constant time step length!
        """
    end
    return indices, first(delta_t)
end


"""
    solve_free_node_temperature_dynamics!(
        heating_temperatures_K::Dict{Object,SpineDataType},
        cooling_temperatures_K::Dict{Object,SpineDataType},
        free_nodes::Dict{Object,AbstractNode},
        set_nodes::Dict{Object,AbstractNode},
        indices::Vector{DateTime},
        delta_t::Number
    )

Solve the free node temperature dynamics, and append them to the temperature dicts.

TODO: Docstring!
"""
function solve_free_node_temperature_dynamics!(
    temperatures_K::Dict{Object,T} where {T<:SpineDataType},
    free_nodes::Dict{Object,AbstractNode},
    set_nodes::Dict{Object,AbstractNode},
    indices::Vector{DateTime},
    delta_t::Number
)
    for (node, node_data) in free_nodes
        # Account for set temperature node heat transfers
        effective_self_discharge_W_K = (
            node_data.self_discharge_coefficient_W_K +
            sum(
                get(node_data.heat_transfer_coefficients_W_K, set_node, 0.0)
                for (set_node, set_node_data) in set_nodes
            )
        )
        effective_external_load_W = collect(
            values(
                node_data.external_load_W +
                sum(
                    get(node_data.heat_transfer_coefficients_W_K, set_node, 0.0) *
                    temperatures_K[set_node]
                    for (set_node, set_node_data) in set_nodes
                )
            )
        )

        # Initialize the temperature from the steady-state.
        temps_K = zeros(1 + length(indices))
        temps_K[1] = effective_external_load_W[1] / effective_self_discharge_W_K

        # Solve the rest of the temperatures.
        expcoeff = exp( # Luckily this is constant for free temperature nodes (structures), saving us time.
            -effective_self_discharge_W_K /
            node_data.thermal_mass_Wh_K *
            delta_t
        )
        for i in 2:length(temps_K)
            temps_K[i] = (
                expcoeff * temps_K[i-1] +
                effective_external_load_W[i-1] /
                effective_self_discharge_W_K * (1 - expcoeff)
            )
        end
        popfirst!(temps_K) # Remove initial temperature.

        # Add the calculated temperatures to the temperature dictionary
        temperatures_K[node] = TimeSeries(indices, temps_K, false, false)
    end
end



"""
    calculate_final_heating_demand(
        archetype::ArchetypeBuilding,
        temperatures_K::Dict{Object,SpineDataType},
        air_node::Object,
        free_nodes::Dict{Object,AbstractNode}
    )

Calculate the final heating and cooling demands of the interior air node.

TODO: Docstring!
"""
function calculate_final_heating_demand(
    archetype::ArchetypeBuilding,
    temperatures_K::Dict{Object,T} where {T<:SpineDataType},
    air_node::Object,
    free_nodes::Dict{Object,AbstractNode}
)
    # Calculate the heating and cooling demand corrections from free nodes.
    # Set nodes already accounted for in `create_building_weather`.
    heating_correction_W = sum(
        abstract_node.heat_transfer_coefficients_W_K[air_node] *
        (
            archetype.weather_data.heating_set_point_K -
            temperatures_K[node]
        )
        for (node, abstract_node) in free_nodes
    )
    cooling_correction_W = sum(
        abstract_node.heat_transfer_coefficients_W_K[air_node] *
        (
            temperatures_K[node] -
            archetype.weather_data.cooling_set_point_K
        )
        for (node, abstract_node) in free_nodes
    )

    # Calculate the final heating and cooling demands.
    heating_demand_kW = timedata_operation(
        max,
        archetype.weather_data.preliminary_heating_demand_W + heating_correction_W,
        0.0
    ) / 1e3
    cooling_demand_kW = timedata_operation(
        max,
        archetype.weather_data.preliminary_cooling_demand_W + cooling_correction_W,
        0.0
    ) / 1e3
    return heating_demand_kW,
    cooling_demand_kW,
    heating_correction_W,
    cooling_correction_W
end


"""
    solve_dhw_demand(
        archetype::ArchetypeBuilding,
        dhw_node_data::AbstractNode,
        heating_temperatures_K::Dict{Object,SpineDataType},
        cooling_temperatures_K::Dict{Object,SpineDataType},
        hc_ratio::SpineDataType
    )

Solve the approximate domestic hot water demand.
"""
function solve_dhw_demand(
    archetype::ArchetypeBuilding,
    dhw_node_data::AbstractNode,
    temperatures_K::Dict{Object,T} where {T<:SpineDataType},
    hc_ratio::SpineDataType
)
    # Fetch the abstract nodes and omit the dhw node.
    abstract_nodes = copy(archetype.abstract_nodes)
    pop!(abstract_nodes, dhw_node_data.building_node)

    # Calculate the DHW demand for heating and cooling seasons separately.
    dhw_demand_heating_kW = (
        -dhw_node_data.external_load_W +
        dhw_node_data.self_discharge_coefficient_W_K *
        dhw_node_data.heating_set_point_K + sum(
            get(dhw_node_data.heat_transfer_coefficients_W_K, node, 0.0) * (
                dhw_node_data.heating_set_point_K -
                temperatures_K[node]
            )
            for (node, node_data) in abstract_nodes
        )
    ) / 1e3
    dhw_demand_cooling_kW = (
        -dhw_node_data.external_load_W +
        dhw_node_data.self_discharge_coefficient_W_K *
        dhw_node_data.cooling_set_point_K + sum(
            get(dhw_node_data.heat_transfer_coefficients_W_K, node, 0.0) * (
                dhw_node_data.cooling_set_point_K -
                temperatures_K[node]
            )
            for (node, node_data) in abstract_nodes
        )
    ) / 1e3

    # Calculate and return the final estimated DHW demand.
    return (
        dhw_demand_heating_kW * hc_ratio +
        dhw_demand_cooling_kW * (1 - hc_ratio)
    )
end
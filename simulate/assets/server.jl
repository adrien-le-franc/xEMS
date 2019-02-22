# developed with Julia 1.0.3
#
# functions for Stochastic Dynamic Programming 

using JSON, HTTP
using JLD
using StoOpt, ParserSchneider


### init battery parameters

const horizon = Int(60*24/15)
const dt = 15/60

const capacity = Ref(1.)
const power = Ref(0.)
const rc = Ref(0.95)
const rd = Ref(0.95)
const u_max = Ref(power.x*dt)

const states = StoOpt.Grid(0:0.05:1)
const state_steps = StoOpt.grid_steps(states)
const controls = StoOpt.Grid(-1:0.02:1)
const control_iterator = StoOpt.run(controls)

### init data containers

const path_to_data = Ref("")
const path_to_vopt = Ref("")
const site_id = Ref("")

const price_buy = Ref(zeros(horizon, 1))
const price_sell = Ref(zeros(horizon, 1))

# note: improve by introducing vopt struct
const vopt = Ref(Dict())
const k = 10

### cost & dynamics

function dynamics(x, u, w)
        return x + (rc.x*max.(u, 0) - max.(-u, 0)/rd.x)*u_max.x/capacity.x
    end

function stage_cost(price, x, u, w)
	# return Float64
	u = Float64(u...)
    return price[1]*max(0., w[1] + u*u_max.x) - price[2]*max(0., - (w[1] + u*u_max.x))
end

### endpoints

function set_paths(request::HTTP.Request)
	j = HTTP.queryparams(HTTP.URI(request.target))
	path_to_data.x = j["data"]
	path_to_vopt.x = j["vopt"]
	return HTTP.Response(200)
end

function update_site(request::HTTP.Request)

	j = HTTP.queryparams(HTTP.URI(request.target))
	site_id.x = j["site"]

	# identify periods with common prices for the site
	path_to_prices = path_to_data.x*"/submit/$(site_id.x).csv"
	periods = keys(load_prices(path_to_prices))
	return HTTP.Response(200, JSON.json(periods))

end

function update_battery(request::HTTP.Request)

	j = HTTP.queryparams(HTTP.URI(request.target))

	capacity.x = parse(Float64, string(j["capacity"])) / 1000
	power.x = parse(Float64, j["power"]) / 1000
	rc.x = parse(Float64, j["rc"])
	rd.x = parse(Float64, j["rd"])
	u_max.x = power.x*dt

	return HTTP.Response(200)

end

function update_period(request::HTTP.Request)

	j = HTTP.queryparams(HTTP.URI(request.target))
	period = j["period"]
	# note: this repetition per period can be avoid
	path_to_prices = path_to_data.x*"/submit/$(site_id.x).csv"
	prices = load_prices(path_to_prices)
	for key in keys(prices)
		if period in key
			price_buy.x = prices[key]["buy"]'
			price_sell.x = prices[key]["sell"]'
			return HTTP.Response(200)
		end
	end
	error("no price found for site $(site_id.x), period $(period)")
end

function load_vopt(request::HTTP.Request)

	j = HTTP.queryparams(HTTP.URI(request.target))
	path = j["path"]

	vopt.x = load(path)["vopt"]
	return HTTP.Response(200)

end

function compute_vopt(request::HTTP.Request)

	j = HTTP.queryparams(HTTP.URI(request.target))
	path = j["path"]
	season = j["season"]
	winter = season == "w"
	summer = season == "s"
	day = j["day"]
	weekday = day == "weekday"
	weekend = day == "weekend"

	data = load_schneider(path_to_data.x*"/train/$(site_id.x).csv", winter=winter,
		summer=summer, weekday=weekday, weekend=weekend)
	pv = data["pv"]
	load = data["load"]
	noise = StoOpt.Noise(load-pv, k)
	# note: vraiment pas ouf, faire une classe
	prices = hcat(price_buy.x, price_sell.x)

	vopt.x = compute_value_functions(noise, controls, states, dynamics, stage_cost, prices, 
		horizon)

	save(path, "vopt", vopt.x)

	return HTTP.Response(200)

end

function compute_soc(request::HTTP.Request)

	j = HTTP.queryparams(HTTP.URI(request.target))
	current_soc = [parse(Float64, j["current_soc"])]
	forecast_noise_15 = parse(Float64, j["forecast_noise_15"]) / 1000
	time_step = parse(Int64, j["time_step"])
	prices = [price_buy.x[time_step], price_sell.x[time_step]]

	uopt = compute_online_policy(current_soc, [forecast_noise_15], prices, states, 
		control_iterator, vopt.x[time_step], dynamics, stage_cost, state_steps)

	next_soc = dynamics(current_soc, uopt, 0.) 

	return HTTP.Response(200, JSON.json(Float64(next_soc...)))
end 

### make a router and add routes for endpoints

const router = HTTP.Router()
HTTP.@register(router, "GET", "/set_paths", set_paths)
HTTP.@register(router, "GET", "/update_site", update_site)
HTTP.@register(router, "GET", "/update_battery", update_battery)
HTTP.@register(router, "GET", "/update_period", update_period)
HTTP.@register(router, "GET", "/load_vopt", load_vopt)
HTTP.@register(router, "GET", "/compute_vopt", compute_vopt)
HTTP.@register(router, "GET", "/compute_soc", compute_soc)

### create and run server

HTTP.serve(router, "0.0.0.0", 8000; verbose=true)
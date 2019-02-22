# ==============================================================================
#    THIS CLASS WILL BE IMPLEMENTED BY COMPETITORS
# ==============================================================================

import pdb
import os, requests, subprocess, socket
import time, datetime
from pathlib import Path

class BatteryContoller(object):
    """ The BatteryContoller class handles providing a new "target state of charge"
        at each time step.

        This class is instantiated by the simulation script, and it can
        be used to store any state that is needed for the call to
        propose_state_of_charge that happens in the simulation.

        The propose_state_of_charge method returns the state of
        charge between 0.0 and 1.0 to be attained at the end of the coming
        quarter, i.e., at time t+15 minutes.

        The arguments to propose_state_of_charge are as follows:
        :param site_id: The current site (building) id in case the model does different work per site
        :param timestamp: The current timestamp inlcuding time of day and date
        :param battery: The battery (see battery.py for useful properties, including current_charge and capacity)
        :param actual_previous_load: The actual load of the previous quarter.
        :param actual_previous_pv_production: The actual PV production of the previous quarter.
        :param price_buy: The price at which electricity can be bought from the grid for the
          next 96 quarters (i.e., an array of 96 values).
        :param price_sell: The price at which electricity can be sold to the grid for the
          next 96 quarters (i.e., an array of 96 values).
        :param load_forecast: The forecast of the load (consumption) established at time t for the next 96
          quarters (i.e., an array of 96 values).
        :param pv_forecast: The forecast of the PV production established at time t for the next
          96 quarters (i.e., an array of 96 values).

        :returns: proposed state of charge, a float between 0 (empty) and 1 (full).
    """

    def __init__(self, url="http://localhost:8000"):

        self.site_id = None
        self.battery_id = None
        self.capacity = None
        self.power = None
        self.rc = 0.95
        self.rd = 0.95
        self.period_id = None
        self.new_period = True
        
        self.path_to_vopt = None
        self.path_to_data = None
        self.current_vopt_path = None
        self.period_to_group = {}

        self.url = url

        #self.launch_server()
        self.init_paths()

    def launch_server(self):

        local_path = os.path.dirname(os.path.abspath(__file__))
        path_to_assets = os.path.join(local_path, "assets")

        command = "julia --project={} {}/server.jl 2> /tmp/server.log &".format(path_to_assets, 
            path_to_assets)
        subprocess.call(command, shell=True)

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        result = sock.connect_ex(("0.0.0.0", 8000))

        # wait for server deployment
        while(result != 0):
            print("Waiting for server at {}".format(self.url))
            time.sleep(1)
            result = sock.connect_ex(("0.0.0.0", 8000))

    def init_paths(self):

        local_path = os.path.dirname(os.path.abspath(__file__))
        self.path_to_vopt = os.path.join(local_path, "assets/vopt")
        simulation_dir = (Path(__file__)/os.pardir/os.pardir).resolve()
        self.path_to_data = os.path.join(simulation_dir, "data")

        # directory to store vopt
        try:
            os.makedirs(self.path_to_vopt)
        except OSError:
            pass

        # request to set paths
        args = {"data": self.path_to_data, "vopt": self.path_to_vopt}
        r = requests.get(self.url+"/set_paths", params=args)
        
    def set_site(self, site_id):

        self.site_id = str(site_id)

        # directory to store vopt for current site 
        path_to_vopt_site = os.path.join(self.path_to_vopt, "site_"+self.site_id)
        try:
            os.makedirs(path_to_vopt_site)
        except OSError:
            pass

        # request to set site id and get fixed price periods grouping
        r = requests.get(self.url+"/update_site/?site={}".format(self.site_id))
        periods = r.json()
        grouped_periods = {str(i+1):periods[i] for i in range(len(periods))}
        period_to_price = {}
        for key, values in grouped_periods.items():
            for period in values:
                period_to_price[period] = key
        self.period_to_price = period_to_price

    def set_battery(self, battery, battery_id):

        self.battery_id = str(battery_id)
        self.capacity = battery.capacity
        self.power = battery.charging_power_limit
        self.rc = battery.charging_efficiency
        self.rd = battery.discharging_efficiency

        # directory to store vopt for current battery
        path_to_vopt_site = os.path.join(self.path_to_vopt, "site_"+self.site_id)
        path_to_vopt_battery = os.path.join(path_to_vopt_site, "battery_"+self.battery_id)
        try:
            os.makedirs(path_to_vopt_battery)
        except OSError:
            pass

        # request to send battery information
        args = {"capacity": self.capacity, "power": self.power, "rc": self.rc, "rd": self.rd}
        r = requests.get(self.url+"/update_battery", params=args)

    def set_period(self, period_id):

        self.period_id = str(period_id)
        self.price_id = self.period_to_price[self.period_id]
        self.new_period = True

        # request to send period id
        r = requests.get(self.url+"/update_period/?period={}".format(period_id))

    def season(self, month):
        if month in [1, 2, 3, 4, 10, 11, 12]:
            return "w"
        elif month in [5, 6, 7, 8, 9]:
            return "s"
        else:
            raise ValueError("{} is not a month".format(month))

    def weekday(self, day):
        if day in [0, 1, 2, 3, 4]:
            return "weekday"
        elif day in [5, 6]:
            return "weekend"
        else:
            raise ValueError("{} is not a week day".format(day))

    def load_vopt(self):
        r = requests.get(self.url+"/load_vopt/?path={}".format(self.current_vopt_path))

    def compute_vopt(self, season, day):
        args = {"path":self.current_vopt_path, "season":season, "day":day}
        r = requests.get(self.url+"/compute_vopt", params=args)

    def get_soc(self, current_soc, forecast_noise_15, time_step):
        args = {"current_soc": current_soc, "forecast_noise_15": forecast_noise_15, 
            "time_step": time_step}
        r = requests.get(self.url+"/compute_soc", params=args)
        return r.json()

    def propose_state_of_charge(self,
                                timestamp,
                                battery,
                                actual_previous_load,
                                actual_previous_pv_production,
                                price_buy,
                                price_sell,
                                load_forecast,
                                pv_forecast):

        date = str(timestamp).split(" ")
        day = date[0]
        timer = date[1]
        
        if self.new_period or timer == "00:00:00":

            self.new_period = False
            yyyymmdd = [int(float(i)) for i in day.split("-")]
            date = datetime.date(*yyyymmdd)

            season = self.season(date.month)
            day = self.weekday(date.weekday())

            self.current_vopt_path = os.path.join(self.path_to_vopt, "site_"+self.site_id,
                "battery_"+self.battery_id, "vopt_price_{}_{}_{}.jld".format(
                    self.price_id, season, day))

            if os.path.isfile(self.current_vopt_path):
                print("\n")
                print("load vopt")
                print("\n")
                self.load_vopt()
            else:
                print("\n")
                print("compute vopt")
                print("\n")
                self.compute_vopt(season, day)
        
        h = int(timer[0:2])
        m = int(timer[3:5])
        t = 4*h + m/15 + 1

        current_soc = battery.current_charge
        forecast_load_15 = load_forecast[0]
        forecast_pv_15 = pv_forecast[0]
        forecast_noise_15 = forecast_load_15 - forecast_pv_15

        target_soc = self.get_soc(current_soc, forecast_noise_15, int(t))

        print(target_soc)       


        
        

        return 1.0
import numpy as np

class Trade:
    def __init__(self, entry = np.nan, tp = np.nan, sl = np.nan, on = False, payload = None):
        # Private variables
        self.__on = on
        self.__entry = entry
        self.__tp = tp
        self.__sl = sl
        self.__payload = payload

    @property
    def payload(self):
        """Getter for payload."""
        return self.__payload

    @property
    def entry(self):
        """Getter for entry."""
        return self.__entry

    @property
    def tp(self):
        """Getter for tp."""
        return self.__tp

    @property
    def sl(self):
        """Getter for sl."""
        return self.__sl
    
    @property
    def on(self):
        """Getter for on."""
        return self.__on
    
    #------------------------------------- Computed properties
    @property
    def is_long(self):
        return self.__tp > self.__sl
    
    @property
    def is_short(self):
        return self.__tp < self.__sl
    
    @property
    def rrr(self):
        if self.__on:
            return abs((self.tp - self.entry)/(self.sl - self.entry))
        else: return None

    #------------------------------------- Setters
    @entry.setter
    def entry(self, value):
        if isinstance(value, (float, int)):
            self.__entry = value
        else:
            raise ValueError("Entry is invalid")

    @tp.setter
    def tp(self, value):
        if isinstance(value, (float, int)):
            self.__tp = value
        else:
            raise ValueError("TP is invalid")

    @sl.setter
    def sl(self, value):
        if isinstance(value, (float, int)):
            self.__sl = value
        else:
            raise ValueError("SL is invalid")
        
    #------------------------------------- Methods
    def activate(self):
        self.__on = True
        return self
    
    def clear(self):
        self.__entry = np.nan
        self.__tp = np.nan
        self.__sl = np.nan
        self.__on = False
        self.__payload = None
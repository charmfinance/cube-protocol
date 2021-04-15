
class Sim(object):
    EPS = 1e-9

    def __init__(self, depositWithdrawFee, protocolFee, fundingFee):
        self.depositWithdrawFee = depositWithdrawFee
        self.protocolFee = protocolFee
        self.fundingFee = fundingFee

        self.totalSupply = defaultdict(float)
        self.price = defaultdict(float)
        self.funding = defaultdict(lambda: 1.0)
        self.lastUpdate = defaultdict(float)
        self.poolBalance = 0

    def updatePrice(self, cubeToken, price, t):
        self.funding[cubeToken] *= self._funding(cubeToken, t)
        self.price[cubeToken] = price
        self.lastUpdate[cubeToken] = t

    def deposit(self, cubeToken, ethIn, t):
        fees = ethIn * self.depositWithdrawFee
        netEthIn = ethIn - fees

        quantityOut = netEthIn / self.price(cubeToken, t)
        self.totalSupply[cubeToken] += quantityOut
        self.poolBalance += ethIn

        protocolFees = fees * self.protocolFee
        self.poolBalance -= protocolFees
        return quantityOut

    def withdraw(self, cubeToken, quantityIn, t):
        ethOut = quantityIn * self.price(cubeToken, t)
        fees = ethOut * self.depositWithdrawFee
        netEthOut = ethOut - fees

        self.totalSupply[cubeToken] -= quantityIn
        self.poolBalance -= ethOut
        assert self.totalSupply[cubeToken] > -Sim.EPS

        protocolFees = fees * self.protocolFee
        self.poolBalance += protocolFees
        return netEthOut

    def price(self, cubeToken, t):
        if self.totalEquity() > 0:
            return (
                self.price[cubeToken]
                * self.poolBalance * 1e18
                * self.funding[cubeToken]
                * self._funding(cubeToken, t)
                / self.totalEquity()
            )
        else:
            return self.funding[cubeToken] * self._funding(cubeToken, t)

    def totalEquity(self):
        return sum(
            self.totalSupply[cubeToken] * self.price[cubeToken] * 1e36
            for cubeToken in self.quantities
        )

    def _funding(self, cubeToken, t):
        dt = t - self.lastUpdate[cubeToken]
        return self.fundingFee * self.price[cubeToken] * self.totalSupply[cubeToken] * dt / 86400


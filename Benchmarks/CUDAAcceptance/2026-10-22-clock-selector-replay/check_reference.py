import unittest
from fractions import Fraction
from exact_division import rounded,value,word
from reference import evaluate


class WrittenSelectorControls(unittest.TestCase):
    def evaluate(self,step=0,batch=0,limit=1,stopped=0,speed=2):
        cf=dict(stepIndex=0,batchTime=1,timeLimit=2,stopped=3)
        uf=dict(cfl=0,dx=1,maxStep=2,forcedStep=3)
        return evaluate([step,word(batch),word(limit),stopped],
            [word(.5),word(4),0,0],word(speed),cf,uf)

    def test_first_step_clips_and_stops(self):
        self.assertEqual(self.evaluate(limit=.25),dict(dtWord=word(.25),stopped=2,proposalWord=word(1)))

    def test_later_step_stops_batch_without_clipping(self):
        self.assertEqual(self.evaluate(step=1,batch=.75),dict(dtWord=0,stopped=1,proposalWord=word(1)))

    def test_prior_stop_and_nonphysical_speed(self):
        self.assertEqual(self.evaluate(stopped=2)['dtWord'],0)
        self.assertEqual(self.evaluate(stopped=2)['stopped'],2)
        self.assertEqual(self.evaluate(speed=float('nan'))['stopped'],3)

    def test_nearest_even_ties(self):
        a,b,c=map(Fraction,[value(0x3f800000),value(0x3f800001),value(0x3f800002)])
        self.assertEqual(rounded((a+b)/2),0x3f800000)
        self.assertEqual(rounded((b+c)/2),0x3f800002)


if __name__=='__main__':unittest.main()

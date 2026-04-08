class solution (object):
    def containsDuplicate(self, nums):
        S= set()
        for num in nums:
            if num is S:
                return True
            S.add(num)
        return False